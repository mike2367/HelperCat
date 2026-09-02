import fnmatch
import json
import os
import re
import socket
import subprocess
import time
import uuid
from pathlib import Path

from src.model.utils.paths import resolve_local_path


class JsonRedisFallback:
    def __init__(self, redis_config, db_name):
        db = redis_config.get("dbs", {}).get(db_name, 0)
        data_dir = redis_config.get("data_dir") or "output/conversation/redis_fallback"
        self.path = resolve_local_path(data_dir) / "json_fallback" / f"db_{db}.json"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.data = self._load()

    def _load(self):
        if not self.path.exists():
            return {"strings": {}, "hashes": {}, "sets": {}, "zsets": {}}
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            backup_path = self.path.with_suffix(f".corrupt-{int(time.time())}.json")
            self.path.replace(backup_path)
            return {"strings": {}, "hashes": {}, "sets": {}, "zsets": {}}
        for store in ("strings", "hashes", "sets", "zsets"):
            data.setdefault(store, {})
        return data

    def _save(self):
        self.path.write_text(json.dumps(self.data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")

    def ping(self):
        return True

    def config_set(self, name, value):
        return True

    def get(self, key):
        return self.data["strings"].get(key)

    def set(self, key, value):
        self.data["strings"][key] = str(value)
        self._save()

    def exists(self, *keys):
        stores = ("strings", "hashes", "sets", "zsets")
        return sum(any(key in self.data[store] for store in stores) for key in keys)

    def hset(self, name, key=None, value=None, mapping=None):
        bucket = self.data["hashes"].setdefault(name, {})
        if mapping is not None:
            bucket.update({str(k): str(v) for k, v in mapping.items()})
        elif key is not None:
            bucket[str(key)] = str(value)
        self._save()

    def hget(self, name, key):
        return self.data["hashes"].get(name, {}).get(key)

    def hgetall(self, name):
        return dict(self.data["hashes"].get(name, {}))

    def hdel(self, name, *keys):
        bucket = self.data["hashes"].get(name, {})
        for key in keys:
            bucket.pop(str(key), None)
        self._save()

    def sadd(self, name, *members):
        values = self.data["sets"].setdefault(name, [])
        for value in members:
            if value not in values:
                values.append(value)
        self._save()

    def smembers(self, name):
        return set(self.data["sets"].get(name, []))

    def scan_iter(self, pattern):
        keys = set()
        for store in ("strings", "hashes", "sets", "zsets"):
            keys.update(self.data[store].keys())
        for key in keys:
            if fnmatch.fnmatch(key, pattern):
                yield key

    def delete(self, *keys):
        for key in keys:
            for store in ("strings", "hashes", "sets", "zsets"):
                self.data[store].pop(key, None)
        self._save()

    def zadd(self, name, mapping):
        bucket = self.data["zsets"].setdefault(name, {})
        for member, score in mapping.items():
            bucket[member] = float(score)
        self._save()

    def zcard(self, name):
        return len(self.data["zsets"].get(name, {}))

    def zremrangebyrank(self, name, start, end):
        bucket = self.data["zsets"].setdefault(name, {})
        members = [member for member, _ in sorted(bucket.items(), key=lambda item: item[1])]
        if end == -1:
            selected = members[start:]
        else:
            selected = members[start : end + 1]
        for member in selected:
            bucket.pop(member, None)
        self._save()

    def zrange(self, name, start, end, withscores=False):
        values = sorted(self.data["zsets"].get(name, {}).items(), key=lambda item: item[1])
        members = values if withscores else [member for member, _ in values]
        if end == -1:
            return members[start:]
        return members[start : end + 1]

    def type(self, name):
        for store, kind in (("strings", "string"), ("hashes", "hash"), ("sets", "set"), ("zsets", "zset")):
            if name in self.data[store]:
                return kind
        return "none"

    def zrangebyscore(self, name, min_score, max_score):
        min_value = float("-inf") if min_score == "-inf" else float(min_score)
        max_value = float("inf") if max_score == "+inf" else float(max_score)
        return [
            member
            for member, score in sorted(self.data["zsets"].get(name, {}).items(), key=lambda item: item[1])
            if min_value <= score <= max_value
        ]


class db_operations:
    @staticmethod
    def _server_executable(redis_config):
        executable = redis_config.get("server_executable", "redis-server")
        if str(executable).lower().endswith(".exe") and os.name != "nt":
            converted = subprocess.run(
                ["wslpath", "-u", str(executable)],
                capture_output=True,
                text=True,
                check=False,
            ).stdout.strip()
            return converted or executable
        return executable

    @staticmethod
    def ensure_server(redis_config):
        if db_operations._can_connect(redis_config):
            return
        if not redis_config.get("auto_start", False):
            raise ConnectionError("Redis is not reachable and auto_start is disabled")

        original_executable = redis_config.get("server_executable", "redis-server")
        executable = db_operations._server_executable(redis_config)
        windows_executable = str(original_executable).lower().endswith(".exe")
        port = str(redis_config.get("port", 6379))
        command = [executable, "--port", port]
        data_dir = redis_config.get("data_dir")
        if data_dir:
            data_dir = resolve_local_path(data_dir)
            data_dir.mkdir(parents=True, exist_ok=True)
            if windows_executable and os.name != "nt":
                data_dir = Path(
                    subprocess.run(
                        ["wslpath", "-w", str(data_dir)],
                        capture_output=True,
                        text=True,
                        check=True,
                    ).stdout.strip()
                )
            command.extend(["--dir", str(data_dir)])
        if windows_executable and os.name != "nt":
            command.extend(["--bind", "127.0.0.1", db_operations._connection_host(redis_config)])
        if redis_config.get("appendonly", True):
            command.extend(["--appendonly", "yes"])
        else:
            command.extend(["--appendonly", "no"])
        if redis_config.get("save") is not None:
            command.extend(["--save", str(redis_config["save"])])
        creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=creationflags)

        deadline = time.time() + redis_config.get("startup_timeout_seconds", 5)
        while time.time() < deadline:
            if db_operations._can_connect(redis_config):
                return
            time.sleep(0.1)
        raise ConnectionError("Redis did not become reachable after startup")

    @staticmethod
    def _can_connect(redis_config):
        try:
            with socket.create_connection(
                (db_operations._connection_host(redis_config), redis_config.get("port", 6379)),
                timeout=0.3,
            ):
                return True
        except OSError:
            return False

    @staticmethod
    def _connection_host(redis_config):
        host = redis_config.get("host", "127.0.0.1")
        if host != "wsl_gateway" or os.name == "nt":
            return "127.0.0.1" if host == "wsl_gateway" else host
        route = subprocess.run(
            ["ip", "route", "show", "default"],
            capture_output=True,
            text=True,
            check=False,
        ).stdout
        match = re.search(r"default via ([^\s]+)", route)
        if not match:
            raise ConnectionError("Could not resolve the Windows host gateway for Redis")
        return match.group(1)

    @staticmethod
    def client(redis_config, db_name):
        try:
            import redis

            db_operations.ensure_server(redis_config)
            db = redis_config.get("dbs", {}).get(db_name, 0)
            connection = redis.Redis(
                host=db_operations._connection_host(redis_config),
                port=redis_config.get("port", 6379),
                db=db,
                password=redis_config.get("password"),
                decode_responses=True,
                protocol=2,
            )
            db_operations._configure_persistence(connection, redis_config)
            if db_name == "user_memory":
                db_operations.migrate_legacy_user_data(redis_config, connection)
            return connection
        except Exception:
            if redis_config.get("allow_json_fallback", True):
                return JsonRedisFallback(redis_config, db_name)
            raise

    @staticmethod
    def _configure_persistence(connection, redis_config):
        connection.ping()

    @staticmethod
    def key(redis_config, *parts):
        prefix = redis_config.get("key_prefix", "cat")
        return ":".join([prefix, *[str(part) for part in parts]])

    @staticmethod
    def user_key(redis_config, user_id, *parts):
        from src.model.memory.cache_crypto import protected_user_id

        return db_operations.key(redis_config, "User", protected_user_id(redis_config, user_id), *parts)

    @staticmethod
    def _encode(redis_config, value):
        from src.model.memory.cache_crypto import encrypt_redis_value

        return encrypt_redis_value(redis_config, value)

    @staticmethod
    def _decode(redis_config, value):
        from src.model.memory.cache_crypto import decrypt_redis_value

        return decrypt_redis_value(redis_config, value)

    @staticmethod
    def migrate_legacy_user_data(redis_config, client):
        if not redis_config.get("encryption", {}).get("enabled") or int(redis_config.get("port", 6379)) != 6379:
            return
        prefix = str(redis_config.get("key_prefix", "cat"))
        migrated = False
        for pattern in (f"{prefix}:user:*:profile", f"{prefix}:memory:*", f"{prefix}:User.*:*"):
            for legacy_key in list(client.scan_iter(pattern)):
                legacy_key = str(legacy_key)
                if legacy_key.startswith(f"{prefix}:user:"):
                    body = legacy_key[len(f"{prefix}:user:") :]
                    user_id, separator, suffix = body.partition(":")
                    if suffix != "profile":
                        continue
                    target = db_operations.user_key(redis_config, user_id, suffix)
                else:
                    body = legacy_key[len(prefix) + 1 :]
                    if body.startswith("memory:"):
                        user_id, separator, suffix = body[len("memory:") :].partition(":")
                        if not separator:
                            continue
                        target = db_operations.user_key(redis_config, user_id, *suffix.split(":"))
                    elif body.startswith("User."):
                        protected_id, separator, suffix = body[len("User.") :].partition(":")
                        if not separator:
                            continue
                        target = db_operations.key(redis_config, "User", protected_id, *suffix.split(":"))
                    else:
                        continue
                kind = client.type(legacy_key)
                if kind == "hash":
                    client.hset(target, mapping={name: db_operations._encode(redis_config, value) for name, value in client.hgetall(legacy_key).items()})
                elif kind == "set":
                    values = [db_operations._encode(redis_config, value) for value in client.smembers(legacy_key)]
                    if values:
                        client.sadd(target, *values)
                elif kind == "zset":
                    values = client.zrange(legacy_key, 0, -1, withscores=True)
                    if values:
                        client.zadd(target, {db_operations._encode(redis_config, value): score for value, score in values})
                elif kind == "string":
                    value = client.get(legacy_key)
                    if value is not None:
                        client.set(target, db_operations._encode(redis_config, value))
                else:
                    continue
                client.delete(legacy_key)
                migrated = True
        if migrated and hasattr(client, "bgrewriteaof"):
            try:
                client.bgrewriteaof()
            except Exception:
                pass

    @staticmethod
    def clear_legacy_schema(redis_config):
        if not redis_config.get("encryption", {}).get("enabled") or int(redis_config.get("port", 6379)) != 6379:
            return
        try:
            import redis

            client = redis.Redis(
                host=db_operations._connection_host(redis_config),
                port=redis_config.get("port", 6379),
                db=0,
                password=redis_config.get("password"),
                decode_responses=True,
                protocol=2,
            )
            keys = list(client.scan_iter(db_operations.key(redis_config, "schema", "*")))
            if keys:
                client.delete(*keys)
                client.bgrewriteaof()
        except Exception:
            return

    @staticmethod
    def save_user_profile(redis_config, user_id, user_profile):
        client = db_operations.client(redis_config, "user_memory")
        key = db_operations.user_key(redis_config, user_id, "profile")
        mapping = {
            name: db_operations._encode(redis_config, json.dumps(value, ensure_ascii=False, separators=(",", ":")))
            for name, value in user_profile.items()
            if value not in (None, "", [])
        }
        if mapping:
            client.hset(key, mapping=mapping)

    @staticmethod
    def load_user_profile(redis_config, user_id):
        client = db_operations.client(redis_config, "user_memory")
        key = db_operations.user_key(redis_config, user_id, "profile")
        return {name: json.loads(db_operations._decode(redis_config, value)) for name, value in client.hgetall(key).items()}

    @staticmethod
    def append_memory_event(redis_config, user_id, event, max_events):
        client = db_operations.client(redis_config, "user_memory")
        key = db_operations.user_key(redis_config, user_id, "events")
        encoded = db_operations._encode(redis_config, json.dumps(event, ensure_ascii=False, separators=(",", ":")))
        client.zadd(key, {encoded: event["t"]})
        overflow = client.zcard(key) - max_events
        if overflow > 0:
            client.zremrangebyrank(key, 0, overflow - 1)

    @staticmethod
    def load_memory_events(redis_config, user_id, limit):
        client = db_operations.client(redis_config, "user_memory")
        events = []
        for role in ("user", "assistant"):
            key = db_operations.user_key(redis_config, user_id, "conversation", role)
            for value in client.zrange(key, 0, -1):
                event = json.loads(db_operations._decode(redis_config, value))
                events.append(
                    {
                        "id": event.get("id"),
                        "t": event.get("recorded_at_ms", 0),
                        "role": event.get("role", role),
                        "txt": event.get("text", ""),
                        "request_id": event.get("request_id"),
                    }
                )
        if not events:
            key = db_operations.user_key(redis_config, user_id, "events")
            events = [json.loads(db_operations._decode(redis_config, value)) for value in client.zrange(key, 0, -1)]
        events.sort(key=lambda event: event.get("t", 0))
        return events[-limit:] if limit else events

    @staticmethod
    def append_conversation_entry(redis_config, user_id, entry, max_entries):
        client = db_operations.client(redis_config, "user_memory")
        role = str(entry.get("role", "unknown")).strip().lower()
        key = db_operations.user_key(redis_config, user_id, "conversation", role)
        encoded = db_operations._encode(redis_config, json.dumps(entry, ensure_ascii=False, separators=(",", ":")))
        client.zadd(key, {encoded: entry["recorded_at_ms"]})
        overflow = client.zcard(key) - max_entries
        if overflow > 0:
            client.zremrangebyrank(key, 0, overflow - 1)

    @staticmethod
    def append_profile_audit(redis_config, user_id, entry, max_entries=500):
        client = db_operations.client(redis_config, "user_memory")
        key = db_operations.user_key(redis_config, user_id, "profile", "audit")
        encoded = db_operations._encode(redis_config, json.dumps(entry, ensure_ascii=False, separators=(",", ":")))
        client.zadd(key, {encoded: entry["recorded_at_ms"]})
        overflow = client.zcard(key) - max_entries
        if overflow > 0:
            client.zremrangebyrank(key, 0, overflow - 1)

    @staticmethod
    def append_kairos_candidate(redis_config, user_id, candidate, max_entries=500):
        client = db_operations.client(redis_config, "user_memory")
        candidate_type = str(candidate.get("type", "unknown")).strip() or "unknown"
        key = db_operations.user_key(redis_config, user_id, "kairos", "candidate", candidate_type)
        encoded = db_operations._encode(redis_config, json.dumps(candidate, ensure_ascii=False, separators=(",", ":")))
        client.zadd(key, {encoded: candidate["recorded_at_ms"]})
        overflow = client.zcard(key) - max_entries
        if overflow > 0:
            client.zremrangebyrank(key, 0, overflow - 1)

    @staticmethod
    def load_kairos_candidates(redis_config, user_id, candidate_type, limit):
        client = db_operations.client(redis_config, "user_memory")
        key = db_operations.user_key(redis_config, user_id, "kairos", "candidate", candidate_type)
        start = -limit if limit else 0
        return [json.loads(db_operations._decode(redis_config, value)) for value in client.zrange(key, start, -1)]

    @staticmethod
    def save_memory_facts(redis_config, user_id, facts):
        if not facts:
            return
        client = db_operations.client(redis_config, "user_memory")
        key = db_operations.user_key(redis_config, user_id, "facts")
        mapping = {name: db_operations._encode(redis_config, json.dumps(value, ensure_ascii=False, separators=(",", ":"))) for name, value in facts.items()}
        client.hset(key, mapping=mapping)

    @staticmethod
    def load_memory_facts(redis_config, user_id):
        client = db_operations.client(redis_config, "user_memory")
        key = db_operations.user_key(redis_config, user_id, "facts")
        return {name: json.loads(db_operations._decode(redis_config, value)) for name, value in client.hgetall(key).items()}

    @staticmethod
    def delete_memory_facts(redis_config, user_id, fields):
        fields = [str(field).strip() for field in fields if str(field).strip()]
        if not fields:
            return
        client = db_operations.client(redis_config, "user_memory")
        client.hdel(db_operations.user_key(redis_config, user_id, "facts"), *fields)

    @staticmethod
    def save_forgotten_profile_fields(redis_config, user_id, fields):
        fields = [str(field).strip() for field in fields if str(field).strip()]
        if not fields:
            return
        client = db_operations.client(redis_config, "user_memory")
        client.sadd(db_operations.user_key(redis_config, user_id, "forgotten_fields"), *(db_operations._encode(redis_config, field) for field in fields))

    @staticmethod
    def load_forgotten_profile_fields(redis_config, user_id):
        client = db_operations.client(redis_config, "user_memory")
        return {db_operations._decode(redis_config, value) for value in client.smembers(db_operations.user_key(redis_config, user_id, "forgotten_fields"))}

    @staticmethod
    def delete_user_profile_fields(redis_config, user_id, fields):
        fields = [str(field).strip() for field in fields if str(field).strip()]
        if not fields:
            return
        client = db_operations.client(redis_config, "user_memory")
        client.hdel(db_operations.user_key(redis_config, user_id, "profile"), *fields)

    @staticmethod
    def append_model_event(redis_config, event, max_events=1000):
        client = db_operations.client(redis_config, "model_ops")
        legacy_key = db_operations.key(redis_config, "model_ops", "events")
        if client.exists(legacy_key):
            for value in client.zrange(legacy_key, 0, -1):
                try:
                    legacy_event = json.loads(value)
                except (TypeError, json.JSONDecodeError):
                    continue
                legacy_type = str(legacy_event.get("type", "unknown")).strip() or "unknown"
                client.zadd(
                    db_operations.key(redis_config, "model_ops", "event", legacy_type),
                    {value: legacy_event.get("t", 0)},
                )
            client.delete(legacy_key)
        event = dict(event)
        event_type = str(event.get("type", "unknown")).strip() or "unknown"
        payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
        request_id = str(payload.get("request_id", "")).strip()
        event["id"] = event.get("id") or uuid.uuid4().hex
        event["type"] = event_type
        event["t"] = int(event.get("t") or time.time())
        event["recorded_at_ms"] = event.get("recorded_at_ms") or int(time.time() * 1000)
        event["category"] = db_operations.model_event_category(event_type)
        event["schema_version"] = 4
        key = db_operations.key(redis_config, "model_ops", "event", event_type)
        encoded = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
        client.zadd(key, {encoded: event["t"]})
        category_key = db_operations.key(redis_config, "model_ops", "category", event["category"], event_type)
        client.zadd(category_key, {encoded: event["recorded_at_ms"]})
        if request_id:
            timeline_key = db_operations.key(redis_config, "model_ops", "request", request_id, "timeline")
            stage_key = db_operations.key(redis_config, "model_ops", "request", request_id, "stage", event_type)
            client.zadd(timeline_key, {encoded: event["recorded_at_ms"]})
            client.zadd(stage_key, {encoded: event["recorded_at_ms"]})
        for event_key in client.scan_iter(db_operations.key(redis_config, "model_ops", "event", "*")):
            overflow = client.zcard(event_key) - max_events
            if overflow > 0:
                client.zremrangebyrank(event_key, 0, overflow - 1)

    @staticmethod
    def model_event_category(event_type):
        if event_type.startswith("deepseek_"):
            return "deepseek"
        if event_type.startswith("kairos_"):
            return "kairos"
        if event_type == "biomedical_rag":
            return "rag"
        if event_type.startswith(("profile_", "memory_")):
            return "memory"
        if event_type.startswith("boundary_"):
            return "qwen"
        if event_type.startswith("server_"):
            return "server"
        if event_type.startswith(("request_", "chat_completion")):
            return "request"
        return "runtime"

    @staticmethod
    def load_model_events(redis_config, limit):
        client = db_operations.client(redis_config, "model_ops")
        events = []
        for key in client.scan_iter(db_operations.key(redis_config, "model_ops", "event", "*")):
            events.extend(json.loads(value) for value in client.zrange(key, 0, -1))
        return sorted(events, key=lambda event: event.get("t", 0))[-limit:] if limit else events
