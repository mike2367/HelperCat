#!/usr/bin/env bash
set -euo pipefail
pause_for_close() {
  local pause_mode="${PAUSE_ON_EXIT:-auto}"
  if [[ "$pause_mode" == "1" || "$pause_mode" == "always" || ( "$pause_mode" == "auto" && ( -t 0 || -n "${MSYSTEM:-}" || -n "${MINGW_PREFIX:-}" ) ) ]]; then
    if [[ -r /dev/tty ]]; then
      read -r -p "Press Enter to close..." < /dev/tty || true
    else
      echo "Press Ctrl-C to close..."
      sleep 3600
    fi
  fi
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$PROJECT_ROOT"

if [[ -n "${TAVILY_API_KEY:-}" ]]; then
  export TAVILY_API_KEY
fi

CONFIG_PYTHON="${CONFIG_PYTHON:-python3}"
TEST_USER_ID="${TEST_USER_ID:-qa_fake_legal_user}"
TEST_MODE="${CAT_TEST_MODE:-}"
if [[ "$TEST_MODE" != "ui" && "$TEST_MODE" != "terminal" ]]; then
  echo "CAT_TEST_MODE must be ui or terminal." >&2
  exit 2
fi
TEST_KEY_PREFIX="${TEST_KEY_PREFIX:-cat_qa_${TEST_MODE}}"
if [[ "$TEST_MODE" == "ui" ]]; then
  EXPECTED_REDIS_PORT=12677
  EXPECTED_KEY_PREFIX=cat_qa_ui
else
  EXPECTED_REDIS_PORT=12678
  EXPECTED_KEY_PREFIX=cat_qa_terminal
fi
if [[ "${CAT_TEST_EXTERNAL_REDIS_PORT:-}" != "$EXPECTED_REDIS_PORT" || "$TEST_KEY_PREFIX" != "$EXPECTED_KEY_PREFIX" ]]; then
  echo "QA Redis route mismatch: ${TEST_MODE} must use port ${EXPECTED_REDIS_PORT} and prefix ${EXPECTED_KEY_PREFIX}." >&2
  exit 2
fi
TEST_RUN_ID="${CAT_TEST_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
TEST_LOG_DIR="$PROJECT_ROOT/src/server/logs/test/$TEST_RUN_ID"
TEST_SERVICE_LOG_DIR="$TEST_LOG_DIR/services"
TEST_RUNTIME_ROOT="$TEST_LOG_DIR/runtime"

TEST_CONVERSATION_CONFIG="$TEST_RUNTIME_ROOT/conversation_config.yaml"
TEST_MEMORY_CONFIG="$TEST_RUNTIME_ROOT/memory_config.yaml"
TEST_DB_CONFIG="$TEST_RUNTIME_ROOT/db_config.yaml"
TEST_KAIROS_CONFIG="$TEST_RUNTIME_ROOT/kairos_config.yaml"
TEST_SERVER_CONFIG="$TEST_RUNTIME_ROOT/server_config.yaml"
TEST_WEBUI_COMPOSE_FILE="$TEST_RUNTIME_ROOT/open_webui_test.compose.yaml"

status() {
  printf '[start_testing] %s\n' "$1"
}

docker_compose() {
  if [[ -z "${DOCKER_BIN:-}" ]]; then
    echo "Docker was not found in PATH." >&2
    return 1
  fi
  local args=()
  while (($#)); do
    if [[ "$1" == "-f" && $# -ge 2 ]]; then
      args+=("-f")
      if [[ "$DOCKER_BIN" == *.exe ]] && command -v wslpath >/dev/null 2>&1; then
        args+=("$(wslpath -w "$2")")
      else
        args+=("$2")
      fi
      shift 2
    else
      args+=("$1")
      shift
    fi
  done
  "$DOCKER_BIN" compose "${args[@]}"
}

find_docker() {
  local candidate
  for candidate in \
    "/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe" \
    "$(command -v docker 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]] && "$candidate" version >/dev/null 2>&1; then
      echo "$candidate"
      return
    fi
  done
}

DOCKER_BIN="${DOCKER_BIN:-$(find_docker || true)}"

terminate_pid_tree() {
  local signal="$1"
  local pid="${2:-}"
  local child
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" >/dev/null 2>&1 || return 0
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    terminate_pid_tree "$signal" "$child"
  done
  kill "-${signal}" "$pid" >/dev/null 2>&1 || true
}

kill_matching() {
  local pattern="$1"
  pkill -TERM -f "$pattern" >/dev/null 2>&1 || true
  sleep 1
  pkill -KILL -f "$pattern" >/dev/null 2>&1 || true
}

cleanup_runtime() {
  if declare -F cleanup_test_webui >/dev/null 2>&1; then
    status "shutting down test Open WebUI"
    cleanup_test_webui
  fi
  terminate_pid_tree TERM "${KAIROS_PID:-}"
  terminate_pid_tree TERM "${MEMORY_PROXY_PID:-}"
  terminate_pid_tree TERM "${VLLM_PID:-}"
  sleep 1
  terminate_pid_tree KILL "${KAIROS_PID:-}"
  terminate_pid_tree KILL "${MEMORY_PROXY_PID:-}"
  terminate_pid_tree KILL "${VLLM_PID:-}"
  [[ -n "${TEST_KAIROS_CONFIG:-}" ]] && kill_matching "src.model.memory.kairos.*${TEST_KAIROS_CONFIG}"
  [[ -n "${TEST_MEMORY_PORT:-}" ]] && kill_matching "src.model.conversation.query_API.*--port ${TEST_MEMORY_PORT}"
  if [[ -z "${CAT_TEST_EXTERNAL_VLLM_URL:-}" && -n "${TEST_VLLM_PORT:-}" ]]; then
    kill_matching "vllm.entrypoints.openai.api_server.*--port ${TEST_VLLM_PORT}"
  fi
  if [[ -f "${TEST_DB_CONFIG:-}" ]]; then
    status "clearing ${TEST_MODE} QA Redis DB1"
    "$CONFIG_PYTHON" - "$TEST_DB_CONFIG" <<'PY' || true
import sys
import yaml

from src.model.utils.db_operations import db_operations

redis_config = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["redis"]
db_operations.client(redis_config, "user_memory").flushdb()
PY
  fi
  if [[ -n "${TEST_RUNTIME_ROOT:-}" && "$TEST_RUNTIME_ROOT" == "$PROJECT_ROOT/src/server/logs/test/"*/runtime ]]; then
    rm -rf -- "$TEST_RUNTIME_ROOT"
  fi
}

on_error() {
  local status_code=$?
  trap - ERR EXIT INT TERM HUP
  echo
  echo "Testing startup failed at line ${BASH_LINENO[0]} with exit code ${status_code}."
  echo "Check ${TEST_LOG_DIR:-src/server/logs} for details."
  cleanup_runtime
  pause_for_close
  exit "$status_code"
}

on_exit() {
  local status_code=$?
  trap - EXIT INT TERM HUP
  cleanup_runtime
  pause_for_close
  exit "$status_code"
}

trap on_error ERR
trap on_exit EXIT INT TERM HUP

wait_until_ready() {
  local url="$1"
  local timeout_seconds="$2"
  local mode="${3:-http}"
  local start_time
  start_time="$(date +%s)"
  until {
    if [[ "$mode" == "openai" ]]; then
      curl -fsS --max-time 5 -H "Authorization: Bearer ${TEST_API_KEY}" "$url" >/dev/null 2>&1
    else
      curl -fsS --max-time 5 "$url" >/dev/null 2>&1
    fi
  }; do
    if (( "$(date +%s)" - start_time >= timeout_seconds )); then
      echo "Test service did not become ready: $url" >&2
      return 1
    fi
    sleep 2
  done
}

mkdir -p "$TEST_SERVICE_LOG_DIR"/{vllm,memory,kairos}
status "isolated runtime: $TEST_RUNTIME_ROOT"
status "fake user: $TEST_USER_ID"
if [[ "$TEST_MODE" == "ui" ]]; then
  status "starting WebUI QA runtime with dedicated Redis, memory proxy, and disposable Open WebUI"
else
  status "starting terminal QA runtime with dedicated Redis and memory proxy"
fi

eval "$(
"$CONFIG_PYTHON" - "$PROJECT_ROOT" "$TEST_RUNTIME_ROOT" "$TEST_USER_ID" "$TEST_KEY_PREFIX" "$TEST_CONVERSATION_CONFIG" "$TEST_MEMORY_CONFIG" "$TEST_DB_CONFIG" "$TEST_KAIROS_CONFIG" "$TEST_SERVER_CONFIG" "$TEST_LOG_DIR" <<'PY'
from pathlib import Path
import json
import os
import socket
import sys
from urllib.parse import urlparse

import yaml

project_root = Path(sys.argv[1]).resolve()
runtime_root = Path(sys.argv[2]).resolve()
user_id = sys.argv[3]
key_prefix = sys.argv[4]
conversation_path = Path(sys.argv[5]).resolve()
memory_path = Path(sys.argv[6]).resolve()
db_path = Path(sys.argv[7]).resolve()
kairos_path = Path(sys.argv[8]).resolve()
server_path = Path(sys.argv[9]).resolve()
log_dir = Path(sys.argv[10]).resolve()
webui_compose_path = runtime_root / "open_webui_test.compose.yaml"


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


ports = {
    "open_webui": free_port(),
    "memory_proxy": free_port(),
    "vllm": free_port(),
    "redis": free_port(),
}
requested_memory_port = os.environ.get("CAT_TEST_MEMORY_PORT", "").strip()
if requested_memory_port:
    ports["memory_proxy"] = int(requested_memory_port)
external_redis_port = os.environ.get("CAT_TEST_EXTERNAL_REDIS_PORT", "").strip()
if external_redis_port:
    ports["redis"] = int(external_redis_port)

requested_webui_port = os.environ.get("CAT_TEST_WEBUI_PORT", "").strip()
external_vllm_url = os.environ.get("CAT_TEST_EXTERNAL_VLLM_URL", "").strip().rstrip("/")
if requested_webui_port:
    ports["open_webui"] = int(requested_webui_port)
if external_vllm_url:
    parsed_vllm_url = urlparse(external_vllm_url)
    if not parsed_vllm_url.hostname or not parsed_vllm_url.port:
        raise SystemExit("CAT_TEST_EXTERNAL_VLLM_URL must include a hostname and port")
    ports["vllm"] = parsed_vllm_url.port

conversation = yaml.safe_load((project_root / "src" / "model" / "conversation" / "config" / "conversation_config.yaml").read_text(encoding="utf-8"))
memory = yaml.safe_load((project_root / "src" / "model" / "memory" / "config" / "memory_config.yaml").read_text(encoding="utf-8"))
db = yaml.safe_load((project_root / "src" / "model" / "memory" / "config" / "db_config.yaml").read_text(encoding="utf-8"))
kairos = yaml.safe_load((project_root / "src" / "model" / "memory" / "config" / "kairos_config.yaml").read_text(encoding="utf-8"))
server = yaml.safe_load((project_root / "src" / "server" / "server_config.yaml").read_text(encoding="utf-8"))

runtime_root.mkdir(parents=True, exist_ok=True)
(runtime_root / "redis").mkdir(parents=True, exist_ok=True)
(runtime_root / "input_cache").mkdir(parents=True, exist_ok=True)
log_dir.mkdir(parents=True, exist_ok=True)

conversation["memory_config_path"] = str(memory_path)
conversation["kairos_config_path"] = str(kairos_path)
memory["db_config_path"] = str(db_path)
memory.setdefault("memory", {})["user_id"] = user_id

db["redis"]["port"] = ports["redis"]
db["redis"]["data_dir"] = str(runtime_root / "redis")
db["redis"]["key_prefix"] = key_prefix
db["redis"]["auto_start"] = not bool(external_redis_port)
db["redis"]["startup_timeout_seconds"] = 10
db["redis"].setdefault("encryption", {})["enabled"] = False

kairos["kairos"]["input_cache_dir"] = str(runtime_root / "input_cache")

server["paths"]["conversation_config"] = str(conversation_path)
server["paths"]["compose_file"] = str(webui_compose_path)
server["paths"]["log_dir"] = str(log_dir)
server["ports"]["open_webui"] = ports["open_webui"]
server["ports"]["memory_proxy"] = ports["memory_proxy"]
server["ports"]["vllm"] = ports["vllm"]

webui_container_name = "helpercat_test_ui"
webui_volume_name = "helpercat_test_ui_data"
webui_compose = {
    "services": {
        "open-webui": {
            "image": "ghcr.io/open-webui/open-webui:v0.10.2",
            "container_name": webui_container_name,
            "restart": "no",
            "environment": {
                "WEBUI_NAME": "HelperCat",
                "WEBUI_AUTH": "True",
                "ENABLE_SIGNUP": "True",
                "ENABLE_PERSISTENT_CONFIG": "False",
                "DEFAULT_USER_ROLE": "user",
                "ENABLE_OPENAI_API": "True",
                "ENABLE_OLLAMA_API": "False",
                "OLLAMA_BASE_URL": f"http://host.docker.internal:{ports['memory_proxy']}",
                "OPENAI_API_BASE_URLS": f"http://host.docker.internal:{ports['memory_proxy']}/v1",
                "OPENAI_API_KEYS": "your_own_local_api_key",
                "OPENAI_API_CONFIGS": '{"0":{"headers":{"X-Cat-WebUI-Chat-Id":"{{CHAT_ID}}","X-Cat-WebUI-Message-Id":"{{MESSAGE_ID}}"}}}',
                "ENABLE_FORWARD_USER_INFO_HEADERS": "True",
                "DEFAULT_MODELS": "HelperCat",
                "DEFAULT_MODEL_METADATA": json.dumps({"capabilities": {"file_context": False, "vision": False, "file_upload": False, "web_search": False, "image_generation": False, "code_interpreter": False, "terminal": False, "citations": False, "status_updates": True, "builtin_tools": False, "memory": False}}, separators=(",", ":")),
                "ENABLE_CODE_EXECUTION": "False",
                "ENABLE_CODE_INTERPRETER": "False",
                "ENABLE_IMAGE_GENERATION": "False",
                "ENABLE_IMAGE_EDIT": "False",
                "USER_PERMISSIONS_CHAT_FILE_UPLOAD": "False",
                "RAG_EMBEDDING_ENGINE": "openai",
                "RAG_OPENAI_API_BASE_URL": f"http://host.docker.internal:{ports['memory_proxy']}/v1",
                "RAG_OPENAI_API_KEY": "your_own_local_api_key",
                "RAG_EMBEDDING_MODEL": "HelperCat",
                "ENABLE_RAG_HYBRID_SEARCH": "False",
                "ENABLE_WEB_SEARCH": "False",
                "ENABLE_SEARCH_QUERY_GENERATION": "False",
                "ENABLE_FOLLOW_UP_GENERATION": "False",
                "ENABLE_AUTOCOMPLETE_GENERATION": "False",
                "ENABLE_TAGS_GENERATION": "False",
                "ENABLE_TITLE_GENERATION": "False",
            },
            "extra_hosts": ["host.docker.internal:host-gateway"],
            "volumes": [
                f"{webui_volume_name}:/app/backend/data",
                f"{project_root / 'src' / 'server' / 'resources' / 'cat-avatar.png'}:/app/backend/open_webui/static/logo.png:ro",
                f"{project_root / 'src' / 'server' / 'resources' / 'cat-avatar.png'}:/app/backend/open_webui/static/favicon.png:ro",
            ],
            "ports": [f"127.0.0.1:{ports['open_webui']}:8080"],
        },
    },
    "volumes": {webui_volume_name: {}},
}

conversation_path.write_text(yaml.safe_dump(conversation, allow_unicode=True, sort_keys=False), encoding="utf-8")
memory_path.write_text(yaml.safe_dump(memory, allow_unicode=True, sort_keys=False), encoding="utf-8")
db_path.write_text(yaml.safe_dump(db, allow_unicode=True, sort_keys=False), encoding="utf-8")
kairos_path.write_text(yaml.safe_dump(kairos, allow_unicode=True, sort_keys=False), encoding="utf-8")
server_path.write_text(yaml.safe_dump(server, allow_unicode=True, sort_keys=False), encoding="utf-8")
webui_compose_path.write_text(yaml.safe_dump(webui_compose, allow_unicode=True, sort_keys=False), encoding="utf-8")

runtime_env = {
    "TEST_RUNTIME_ROOT": str(runtime_root),
    "CAT_SERVER_CONFIG_PATH": str(server_path),
    "CAT_TEST_USER_ID": user_id,
    "CAT_TEST_API_KEY": server["api_key"],
    "CAT_TEST_MODEL_NAME": server["model_name"],
    "CAT_TEST_BASE_MODEL_NAME": server["base_model_name"],
    "CAT_TEST_BASE_MODEL_DIR": server["paths"].get("wsl_base_model_dir", ""),
    "CAT_TEST_ADAPTER_DIR": server["paths"].get("wsl_adapter_dir", ""),
    "CAT_TEST_ADAPTER_SOURCE_DIR": str((project_root / Path(server["paths"]["adapter_dir"].replace("\\", "/"))).resolve()),
    "CAT_TEST_VLLM_HOST": server["hosts"]["vllm"],
    "CAT_TEST_MAX_MODEL_LEN": str(server["vllm"]["max_model_len"]),
    "CAT_TEST_GPU_MEMORY_UTILIZATION": str(server["vllm"]["gpu_memory_utilization"]),
    "CAT_TEST_QUANTIZATION": server["vllm"]["quantization"],
    "CAT_TEST_LOAD_FORMAT": server["vllm"]["load_format"],
    "CAT_TEST_ENFORCE_EAGER": "1" if server["vllm"].get("enforce_eager") else "",
    "CAT_TEST_MEMORY_PORT": str(ports["memory_proxy"]),
    "CAT_TEST_VLLM_PORT": str(ports["vllm"]),
    "CAT_TEST_EXTERNAL_VLLM_URL": external_vllm_url,
    "CAT_TEST_WEBUI_PORT": str(ports["open_webui"]),
    "CAT_TEST_WEBUI_CONTAINER_NAME": webui_container_name,
    "CAT_TEST_WEBUI_COMPOSE_FILE": str(webui_compose_path),
    "CAT_TEST_REDIS_PORT": str(ports["redis"]),
    "CAT_TEST_CONVERSATION_CONFIG_PATH": str(conversation_path),
    "CAT_TEST_MEMORY_CONFIG_PATH": str(memory_path),
    "CAT_TEST_DB_CONFIG_PATH": str(db_path),
}
for key, value in runtime_env.items():
    print(f"{key}={json.dumps(value)}")
PY
)"

TEST_MEMORY_PORT="${CAT_TEST_MEMORY_PORT}"
TEST_VLLM_PORT="${CAT_TEST_VLLM_PORT}"
TEST_API_KEY="${CAT_TEST_API_KEY}"
TEST_MODEL_NAME="${CAT_TEST_MODEL_NAME}"
TEST_BASE_MODEL_NAME="${CAT_TEST_BASE_MODEL_NAME}"
TEST_BASE_MODEL_DIR="${CAT_TEST_BASE_MODEL_DIR}"
TEST_ADAPTER_DIR="${CAT_TEST_ADAPTER_DIR}"
TEST_ADAPTER_SOURCE_DIR="${CAT_TEST_ADAPTER_SOURCE_DIR}"
TEST_VLLM_HOST="${CAT_TEST_VLLM_HOST}"
if [[ "$TEST_MODE" == "ui" ]]; then
  TEST_MEMORY_HOST="0.0.0.0"
else
  TEST_MEMORY_HOST="127.0.0.1"
fi

status "memory proxy port: ${TEST_MEMORY_PORT}"
status "vLLM port: ${TEST_VLLM_PORT}"
status "logs: ${TEST_LOG_DIR}"
: > "$TEST_SERVICE_LOG_DIR/vllm/out.log"
: > "$TEST_SERVICE_LOG_DIR/vllm/err.log"
: > "$TEST_SERVICE_LOG_DIR/memory/out.log"
: > "$TEST_SERVICE_LOG_DIR/memory/err.log"

export VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER:-0}"
export VLLM_USE_V2_MODEL_RUNNER="${VLLM_USE_V2_MODEL_RUNNER:-0}"
export VLLM_ENABLE_V1_MULTIPROCESSING="${VLLM_ENABLE_V1_MULTIPROCESSING:-0}"

if [[ -n "${CAT_TEST_EXTERNAL_VLLM_URL:-}" ]]; then
  status "using existing local vLLM at ${CAT_TEST_EXTERNAL_VLLM_URL}"
  wait_until_ready "${CAT_TEST_EXTERNAL_VLLM_URL%/v1}/v1/models" 60 openai
else
  status "starting local vLLM on ${TEST_VLLM_PORT}"
  status "refreshing isolated adapter from the selected best checkpoint"
  mkdir -p "$TEST_ADAPTER_DIR"
  rsync -a --delete "$TEST_ADAPTER_SOURCE_DIR"/ "$TEST_ADAPTER_DIR"/
  "$CONFIG_PYTHON" -m vllm.entrypoints.openai.api_server \
    --host "$TEST_VLLM_HOST" \
    --port "$TEST_VLLM_PORT" \
    --api-key "$TEST_API_KEY" \
    --model "$TEST_BASE_MODEL_DIR" \
    --served-model-name "$TEST_BASE_MODEL_NAME" \
    --enable-lora \
    --lora-modules "$TEST_MODEL_NAME=$TEST_ADAPTER_DIR" \
    --quantization "${CAT_TEST_QUANTIZATION:-bitsandbytes}" \
    --load-format "${CAT_TEST_LOAD_FORMAT:-bitsandbytes}" \
    --max-model-len "${CAT_TEST_MAX_MODEL_LEN:-4096}" \
    --gpu-memory-utilization "${CAT_TEST_GPU_MEMORY_UTILIZATION:-0.72}" \
    ${CAT_TEST_ENFORCE_EAGER:+--enforce-eager} \
    > "$TEST_SERVICE_LOG_DIR/vllm/out.log" \
    2> "$TEST_SERVICE_LOG_DIR/vllm/err.log" \
    < /dev/null &
  VLLM_PID=$!
  wait_until_ready "http://127.0.0.1:${TEST_VLLM_PORT}/v1/models" 600 openai
fi

status "starting isolated memory proxy on ${TEST_MEMORY_PORT}"
"$CONFIG_PYTHON" -m src.model.conversation.query_API \
  --config "$TEST_CONVERSATION_CONFIG" \
  --serve \
  --host "$TEST_MEMORY_HOST" \
  --port "$TEST_MEMORY_PORT" \
  --backend-url "${CAT_TEST_EXTERNAL_VLLM_URL:-http://127.0.0.1:${TEST_VLLM_PORT}/v1}" \
  --backend-api-key "$TEST_API_KEY" \
  > "$TEST_SERVICE_LOG_DIR/memory/out.log" \
  2> "$TEST_SERVICE_LOG_DIR/memory/err.log" \
  < /dev/null &
MEMORY_PROXY_PID=$!

wait_until_ready "http://127.0.0.1:${TEST_MEMORY_PORT}/health" 180

status "starting isolated idle KAIROS watcher"
"$CONFIG_PYTHON" -m src.model.memory.kairos \
  --watch \
  --kairos-config "$TEST_KAIROS_CONFIG" \
  --memory-config "$TEST_MEMORY_CONFIG" \
  > "$TEST_SERVICE_LOG_DIR/kairos/out.log" \
  2> "$TEST_SERVICE_LOG_DIR/kairos/err.log" \
  < /dev/null &
KAIROS_PID=$!

TEST_WEBUI_PORT="${CAT_TEST_WEBUI_PORT}"
TEST_WEBUI_CONTAINER_NAME="${CAT_TEST_WEBUI_CONTAINER_NAME}"
TEST_WEBUI_COMPOSE_FILE="${CAT_TEST_WEBUI_COMPOSE_FILE}"

cleanup_test_webui() {
  if [[ -n "${TEST_WEBUI_COMPOSE_FILE:-}" && -f "$TEST_WEBUI_COMPOSE_FILE" ]]; then
    docker_compose -f "$TEST_WEBUI_COMPOSE_FILE" down -v >/dev/null 2>&1 || true
  fi
}

WEBUI_STARTED=0
if [[ "$TEST_MODE" == "ui" ]]; then
  if [[ "${CAT_TEST_WEBUI_MANAGED_EXTERNALLY:-0}" == "1" ]]; then
    status "Windows-managed Open WebUI ready: http://127.0.0.1:${TEST_WEBUI_PORT}"
    WEBUI_STARTED=1
  else
    status "starting disposable Open WebUI on ${TEST_WEBUI_PORT}"
    if docker_compose -f "$TEST_WEBUI_COMPOSE_FILE" up -d; then
      status "waiting for disposable Open WebUI startup"
      wait_until_ready "http://127.0.0.1:${TEST_WEBUI_PORT}" 420
      status "test Open WebUI ready: http://127.0.0.1:${TEST_WEBUI_PORT}"
      WEBUI_STARTED=1
    else
      status "disposable Open WebUI skipped; Docker is not reachable from this WSL session"
    fi
  fi
else
  status "Open WebUI skipped in terminal QA mode"
fi

status "interactive test stack: use the WebUI or OpenAI-compatible endpoint for manual QA"

{
  printf 'TEST_RUNTIME_ROOT=%q\n' "$TEST_RUNTIME_ROOT"
  printf 'CAT_SERVER_CONFIG_PATH=%q\n' "$CAT_SERVER_CONFIG_PATH"
  printf 'CAT_TEST_USER_ID=%q\n' "$CAT_TEST_USER_ID"
  printf 'CAT_TEST_MEMORY_PORT=%q\n' "$CAT_TEST_MEMORY_PORT"
  printf 'CAT_TEST_MODE=%q\n' "$TEST_MODE"
  printf 'CAT_TEST_REDIS_PORT=%q\n' "$CAT_TEST_REDIS_PORT"
  printf 'CAT_TEST_KEY_PREFIX=%q\n' "$TEST_KEY_PREFIX"
  printf 'CAT_TEST_WEBUI_PORT=%q\n' "$CAT_TEST_WEBUI_PORT"
  printf 'CAT_TEST_WEBUI_CONTAINER_NAME=%q\n' "$CAT_TEST_WEBUI_CONTAINER_NAME"
} > "$TEST_RUNTIME_ROOT/runtime.env"

echo
status "test stack ready"
echo "  Memory proxy: http://127.0.0.1:${TEST_MEMORY_PORT}/v1"
if [[ "$WEBUI_STARTED" == "1" ]]; then
  echo "  Open WebUI:   http://127.0.0.1:${TEST_WEBUI_PORT}"
else
  echo "  Open WebUI:   skipped"
fi
echo "  Fake user:    ${TEST_USER_ID}"
echo "  Redis DB1:    127.0.0.1:${CAT_TEST_REDIS_PORT} (${TEST_KEY_PREFIX})"
echo "  Config root:  ${TEST_RUNTIME_ROOT}"
echo "  Logs:         ${TEST_LOG_DIR}"
echo

while true; do
  sleep 10
  curl -fsS --max-time 5 "http://127.0.0.1:${TEST_MEMORY_PORT}/health" >/dev/null 2>&1 || {
    echo "Test proxy is no longer healthy." >&2
    exit 1
  }
  if [[ "$WEBUI_STARTED" == "1" && "${CAT_TEST_WEBUI_MANAGED_EXTERNALLY:-0}" != "1" ]]; then
    curl -fsS --max-time 5 "http://127.0.0.1:${TEST_WEBUI_PORT}" >/dev/null 2>&1 || {
      echo "Test Open WebUI is no longer healthy." >&2
      exit 1
    }
    status "still running: proxy ${TEST_MEMORY_PORT} | webui ${TEST_WEBUI_PORT} | $(date '+%Y-%m-%d %H:%M:%S')"
  elif [[ "$WEBUI_STARTED" == "1" ]]; then
    status "still running: proxy ${TEST_MEMORY_PORT} | Windows-managed webui ${TEST_WEBUI_PORT} | $(date '+%Y-%m-%d %H:%M:%S')"
  else
    status "still running: proxy ${TEST_MEMORY_PORT} | webui skipped | $(date '+%Y-%m-%d %H:%M:%S')"
  fi
done
