#!/usr/bin/env bash
set -euo pipefail
trap 'status=$?; echo; echo "Startup failed at line ${LINENO} with exit code ${status}."; echo "Check src/server/logs/official for service details."; if [ -t 0 ]; then read -r -p "Press Enter to close..."; fi; exit "$status"' ERR

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$PROJECT_ROOT"

if [[ -n "${TAVILY_API_KEY:-}" ]]; then
  export TAVILY_API_KEY
fi

MODE="${1:-${MODE:-local}}"
if [[ "$MODE" == "full" ]]; then
  MODE="full-debug"
fi
CONFIG_FILE="${CONFIG_FILE:-src/server/server_config.yaml}"
CONFIG_PYTHON="${CONFIG_PYTHON:-python3}"
RUNTIME_ENV="${CONFIG_FILE%/*}/runtime.env"
if [[ -f "$RUNTIME_ENV" ]]; then
  set -a
  # Test runtime metadata keeps validation on the cloned DB and WebUI instance.
  source "$RUNTIME_ENV"
  set +a
fi
export CAT_SERVER_CONFIG_PATH="$CONFIG_FILE"

case "$MODE" in
  light|local|full-debug|stop) ;;
  *)
    echo "Usage: bash src/server/scripts/start_all.sh [light|local|full|full-debug|stop]" >&2
    exit 2
    ;;
esac

eval "$(
"$CONFIG_PYTHON" - "$CONFIG_FILE" <<'PY'
import shlex
import sys
from pathlib import Path

import yaml

config = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
paths = config["paths"]
ports = config["ports"]
hosts = config["hosts"]
vllm = config["vllm"]

def emit(name, value):
    print(f"{name}={shlex.quote(str(value))}")

emit("PYTHON_BIN", config["python_bin"])
emit("API_KEY", config["api_key"])
emit("MODEL_NAME", config["model_name"])
emit("BASE_MODEL_NAME", config["base_model_name"])
emit("CONVERSATION_CONFIG", paths["conversation_config"])
emit("ADAPTER_DIR", paths["adapter_dir"])
emit("WSL_BASE_MODEL_DIR", paths.get("wsl_base_model_dir", ""))
emit("WSL_ADAPTER_DIR", paths.get("wsl_adapter_dir", ""))
emit("COMPOSE_FILE", paths["compose_file"])
emit("LOG_DIR", paths["log_dir"])
emit("WEBUI_PORT", ports["open_webui"])
emit("MEMORY_PORT", ports["memory_proxy"])
emit("VLLM_PORT", ports["vllm"])
emit("VLLM_HOST", hosts["vllm"])
emit("MEMORY_HOST", hosts["memory_proxy"])
emit("MAX_MODEL_LEN", vllm["max_model_len"])
emit("GPU_MEMORY_UTILIZATION", vllm["gpu_memory_utilization"])
emit("QUANTIZATION", vllm["quantization"])
emit("LOAD_FORMAT", vllm["load_format"])
emit("ENFORCE_EAGER", "1" if vllm.get("enforce_eager") else "0")
for key, value in vllm.get("env", {}).items():
    emit(key, value)
PY
)"

SERVICE_LOG_DIR="$LOG_DIR/official/${HELPERCAT_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}/services"
mkdir -p "$SERVICE_LOG_DIR"/{vllm,memory,kairos}

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
DOCKER_CONFIG_DIR="$PROJECT_ROOT/.docker-codex"
COMPOSE_PATH="$COMPOSE_FILE"
if [[ "$DOCKER_BIN" == *.exe ]] && command -v wslpath >/dev/null 2>&1; then
  COMPOSE_PATH="$(wslpath -w "$COMPOSE_FILE")"
fi

is_http_ready() {
  curl -fsS --max-time 5 "$1" >/dev/null 2>&1
}

is_openai_ready() {
  curl -fsS --max-time 5 -H "Authorization: Bearer ${API_KEY}" "$1" >/dev/null 2>&1
}

wait_until_ready() {
  local name="$1"
  local url="$2"
  local timeout_seconds="$3"
  local mode="${4:-http}"
  local start_time
  start_time="$(date +%s)"

  until { [[ "$mode" == "openai" ]] && is_openai_ready "$url"; } || { [[ "$mode" == "http" ]] && is_http_ready "$url"; }; do
    if (( "$(date +%s)" - start_time >= timeout_seconds )); then
      echo "$name did not become ready: $url" >&2
      return 1
    fi
    sleep 2
  done
}

cloud_api_host() {
  "$CONFIG_PYTHON" - "$CONVERSATION_CONFIG" "$PROJECT_ROOT" <<'PY'
import os
import sys
from pathlib import Path
from urllib.parse import urlparse

import yaml

conversation_path = Path(sys.argv[1])
project_root = Path(sys.argv[2])
conversation = yaml.safe_load(conversation_path.read_text(encoding="utf-8")) or {}
client_path = Path(conversation["deepseek_config_path"])
if not client_path.is_absolute():
    client_path = project_root / client_path
model = (yaml.safe_load(client_path.read_text(encoding="utf-8")) or {})["model"]
base_url_env = str(model.get("base_url_env", "")).strip()
base_url_override = os.environ.get(base_url_env, "").strip() if base_url_env else ""
base_url = base_url_override or model["base_url"]
print(urlparse(str(base_url)).hostname or "")
PY
}

wait_for_cloud_dns() {
  local host start_time elapsed
  host="$(cloud_api_host)"
  if [[ -z "$host" ]]; then
    echo "Cloud API endpoint has no hostname." >&2
    return 1
  fi

  echo "Waiting for WSL DNS to resolve cloud API host: $host"
  start_time="$(date +%s)"
  until "$CONFIG_PYTHON" - "$host" <<'PY' >/dev/null 2>&1
import socket
import sys

socket.getaddrinfo(sys.argv[1], 443, type=socket.SOCK_STREAM)
PY
  do
    elapsed=$(( $(date +%s) - start_time ))
    if (( elapsed >= 120 )); then
      echo "WSL DNS did not resolve cloud API host within 120 seconds: $host" >&2
      return 1
    fi
    if (( elapsed > 0 && elapsed % 10 == 0 )); then
      echo "Still waiting for WSL DNS: $host (${elapsed}s)"
    fi
    sleep 2
  done
  echo "Cloud API DNS ready: $host"
}

kill_matching() {
  local pattern="$1"
  pkill -TERM -f "$pattern" >/dev/null 2>&1 || true
  sleep 1
  pkill -KILL -f "$pattern" >/dev/null 2>&1 || true
}

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

stop_memory_proxy() {
  terminate_pid_tree TERM "${MEMORY_PROXY_PID:-}"
  sleep 1
  terminate_pid_tree KILL "${MEMORY_PROXY_PID:-}"
  kill_matching "src.model.conversation.query_API.*--port ${MEMORY_PORT}"
}

stop_kairos() {
  terminate_pid_tree TERM "${KAIROS_PID:-}"
  sleep 1
  terminate_pid_tree KILL "${KAIROS_PID:-}"
  kill_matching "src.model.memory.kairos.*--watch"
}

stop_vllm() {
  terminate_pid_tree TERM "${VLLM_PID:-}"
  sleep 1
  terminate_pid_tree KILL "${VLLM_PID:-}"
  kill_matching "vllm.entrypoints.openai.api_server.*--port ${VLLM_PORT}"
}

stop_docker_services() {
  if [[ -z "$DOCKER_BIN" ]]; then
    return
  fi
  "$DOCKER_BIN" compose -f "$COMPOSE_PATH" stop open-webui >/dev/null 2>&1 || true
}

stop_all_runtime() {
  stop_memory_proxy
  stop_kairos
  stop_vllm
  stop_docker_services
}

cleanup_on_exit() {
  local status_code=$?
  trap - EXIT INT TERM HUP
  if [[ "${MODE:-}" != "stop" ]]; then
    stop_all_runtime
  fi
  exit "$status_code"
}

trap cleanup_on_exit EXIT INT TERM HUP

prepare_wsl_assets() {
  if [[ -z "$WSL_BASE_MODEL_DIR" || -z "$WSL_ADAPTER_DIR" ]]; then
    return
  fi

  local source_model source_adapter
  source_model="$("$PYTHON_BIN" - <<'PY'
import yaml
from src.model.utils.paths import resolve_local_path
conversation = yaml.safe_load(open("src/model/conversation/config/conversation_config.yaml", encoding="utf-8")) or {}
base_model_dir = conversation.get("base_model_dir")
if not base_model_dir:
    base_model_dir = (yaml.safe_load(open("src/model/train/config/train_config.yaml", encoding="utf-8")) or {})["model_dir"]
print(resolve_local_path(base_model_dir))
PY
)"
  source_adapter="$("$PYTHON_BIN" - "$ADAPTER_DIR" "$PROJECT_ROOT" <<'PY'
from pathlib import Path
import sys
from src.model.utils.paths import resolve_local_path
print(resolve_local_path(sys.argv[1], Path(sys.argv[2])))
PY
)"

  if [[ ! -f "$WSL_BASE_MODEL_DIR/config.json" ]]; then
    echo "Copying base model into WSL native storage: $WSL_BASE_MODEL_DIR"
    mkdir -p "$WSL_BASE_MODEL_DIR"
    rsync -a --info=progress2 "$source_model"/ "$WSL_BASE_MODEL_DIR"/
  fi
  echo "Refreshing LoRA adapter in WSL native storage: $WSL_ADAPTER_DIR"
  mkdir -p "$WSL_ADAPTER_DIR"
  rsync -a --delete "$source_adapter"/ "$WSL_ADAPTER_DIR"/
}

start_vllm() {
  if is_openai_ready "http://127.0.0.1:${VLLM_PORT}/v1/models"; then
    echo "vLLM already ready on ${VLLM_PORT}"
    return
  fi

  prepare_wsl_assets
  local model_dir="$WSL_BASE_MODEL_DIR"
  local adapter_dir="$WSL_ADAPTER_DIR"
  if [[ -z "$model_dir" || ! -f "$model_dir/config.json" ]]; then
    echo "WSL model copy unavailable; falling back to configured model path." >&2
    model_dir="$("$PYTHON_BIN" - <<'PY'
import yaml
from src.model.utils.paths import resolve_local_path
conversation = yaml.safe_load(open("src/model/conversation/config/conversation_config.yaml", encoding="utf-8")) or {}
base_model_dir = conversation.get("base_model_dir")
if not base_model_dir:
    base_model_dir = (yaml.safe_load(open("src/model/train/config/train_config.yaml", encoding="utf-8")) or {})["model_dir"]
print(resolve_local_path(base_model_dir))
PY
)"
  fi
  if [[ -z "$adapter_dir" || ! -f "$adapter_dir/adapter_config.json" ]]; then
    adapter_dir="$("$PYTHON_BIN" - "$ADAPTER_DIR" "$PROJECT_ROOT" <<'PY'
from pathlib import Path
import sys
from src.model.utils.paths import resolve_local_path
print(resolve_local_path(sys.argv[1], Path(sys.argv[2])))
PY
)"
  fi

  echo "Starting vLLM on ${VLLM_PORT}; model loading can take several minutes"
  : > "$SERVICE_LOG_DIR/vllm/out.log"
  : > "$SERVICE_LOG_DIR/vllm/err.log"
  export VLLM_USE_FLASHINFER_SAMPLER
  export VLLM_USE_V2_MODEL_RUNNER
  export VLLM_ENABLE_V1_MULTIPROCESSING

  command=(
    "$PYTHON_BIN" -m vllm.entrypoints.openai.api_server
    --host "$VLLM_HOST"
    --port "$VLLM_PORT"
    --api-key "$API_KEY"
    --model "$model_dir"
    --served-model-name "$BASE_MODEL_NAME"
    --enable-lora
    --lora-modules "$MODEL_NAME=$adapter_dir"
    --quantization "$QUANTIZATION"
    --load-format "$LOAD_FORMAT"
    --max-model-len "$MAX_MODEL_LEN"
    --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
  )
  if [[ "$ENFORCE_EAGER" == "1" ]]; then
    command+=(--enforce-eager)
  fi

  "${command[@]}" > "$SERVICE_LOG_DIR/vllm/out.log" 2> "$SERVICE_LOG_DIR/vllm/err.log" < /dev/null &
  VLLM_PID=$!
  wait_until_ready "vLLM" "http://127.0.0.1:${VLLM_PORT}/v1/models" 600 openai
}

start_memory_proxy() {
  local backend_mode="$1"
  stop_memory_proxy
  sleep 1
  echo "Starting memory proxy on ${MEMORY_PORT} (${backend_mode})"
  : > "$SERVICE_LOG_DIR/memory/out.log"
  : > "$SERVICE_LOG_DIR/memory/err.log"

  command=(
    "$PYTHON_BIN" -m src.model.conversation.query_API
    --config "$CONVERSATION_CONFIG"
    --serve
    --host "$MEMORY_HOST"
    --port "$MEMORY_PORT"
  )
  if [[ "$backend_mode" != "cloud" ]]; then
    command+=(--backend-url "http://127.0.0.1:${VLLM_PORT}/v1" --backend-api-key "$API_KEY")
  fi

  "${command[@]}" > "$SERVICE_LOG_DIR/memory/out.log" 2> "$SERVICE_LOG_DIR/memory/err.log" < /dev/null &
  MEMORY_PROXY_PID=$!
  wait_until_ready "Memory proxy" "http://127.0.0.1:${MEMORY_PORT}/health" 120 http
}

start_kairos() {
  stop_kairos
  echo "Starting idle KAIROS watcher"
  : > "$SERVICE_LOG_DIR/kairos/out.log"
  : > "$SERVICE_LOG_DIR/kairos/err.log"
  "$PYTHON_BIN" -m src.model.memory.kairos --watch \
    --kairos-config src/model/memory/config/kairos_config.yaml \
    --memory-config src/model/memory/config/memory_config.yaml \
    > "$SERVICE_LOG_DIR/kairos/out.log" \
    2> "$SERVICE_LOG_DIR/kairos/err.log" \
    < /dev/null &
  KAIROS_PID=$!
}

migrate_official_user_data() {
  "$PYTHON_BIN" - <<'PY'
import yaml

from src.model.utils.db_operations import db_operations

config = yaml.safe_load(open("src/model/memory/config/db_config.yaml", encoding="utf-8"))["redis"]
db_operations.client(config, "user_memory")
db_operations.clear_legacy_schema(config)
PY
}

start_open_webui() {
  if [[ -z "$DOCKER_BIN" ]]; then
    echo "Docker/Open WebUI skipped: Docker Desktop is not reachable from WSL." >&2
    return 2
  fi
  mkdir -p "$DOCKER_CONFIG_DIR"
  printf '%s\n' '{"auths":{}}' > "$DOCKER_CONFIG_DIR/config.json"
  export DOCKER_CONFIG="$DOCKER_CONFIG_DIR"
  echo "Starting Open WebUI on ${WEBUI_PORT}"
  if ! "$DOCKER_BIN" compose -f "$COMPOSE_PATH" up -d open-webui; then
    return 1
  fi
  wait_until_ready "Open WebUI" "http://127.0.0.1:${WEBUI_PORT}" 180 http
}

if [[ "$MODE" == "stop" ]]; then
  stop_all_runtime
  echo "Stopped vLLM, memory proxy, and project Docker services."
  exit 0
fi

wait_for_cloud_dns
migrate_official_user_data

if [[ "$MODE" == "light" ]]; then
  stop_vllm
  start_memory_proxy cloud
else
  start_vllm
  start_memory_proxy local
fi
start_kairos

WEBUI_STARTED=0
if [[ "${WINDOWS_DOCKER_STARTED:-0}" == "1" ]]; then
  WEBUI_STARTED=1
  echo "Open WebUI was started by the Windows launcher."
elif start_open_webui; then
  WEBUI_STARTED=1
else
  echo "Continuing without Open WebUI."
fi

echo "Deployment services started; use the WebUI and /health endpoints for validation."

echo
echo "Deployment ready in ${MODE} mode. Leave this shell open for a visible operator session; press Ctrl+C to close this watcher."
if [[ "$WEBUI_STARTED" == "1" ]]; then
  echo "  Open WebUI:    http://127.0.0.1:${WEBUI_PORT}"
else
  echo "  Open WebUI:    skipped"
fi
echo "  Memory proxy:  http://127.0.0.1:${MEMORY_PORT}/v1"
if [[ "$MODE" == "light" ]]; then
  echo "  Backend:       DeepSeek cloud backend; local vLLM is stopped"
else
  echo "  vLLM backend:  http://127.0.0.1:${VLLM_PORT}/v1"
fi
echo "  Logs:          $PROJECT_ROOT/$SERVICE_LOG_DIR"
echo

while true; do
  sleep 30
  echo "Still running (${MODE}): Memory http://127.0.0.1:${MEMORY_PORT}/health | $(date '+%Y-%m-%d %H:%M:%S')"
done
