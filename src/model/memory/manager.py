import uuid
from contextvars import ContextVar
from datetime import datetime, timezone
from pathlib import Path

import yaml

from src.model.memory.profile_memory import UserProfileMemory
from src.model.utils.db_operations import db_operations
from src.model.utils.paths import resolve_local_path


CURRENT_REQUEST_ID = ContextVar("cat_request_id", default=None)


class ConversationMemory:
    def __init__(self, config, database_config):
        self._memory_config = dict(config)
        self._database_config = dict(database_config)
        self.enabled = config.get("enabled", True)
        self.user_id = config.get("user_id", "default")
        self.max_events = int(config.get("max_events", 500))
        self.max_model_events = int(config.get("max_model_events", 1000))
        self.max_context_events = int(config.get("max_context_events", 12))
        self.max_context_event_chars = int(config.get("max_context_event_chars", 1800))
        self.max_context_event_item_chars = int(config.get("max_context_event_item_chars", 500))
        self.redis_config = database_config["redis"]
        self.profile = UserProfileMemory(self.redis_config, self.user_id)

    @classmethod
    def from_yaml(cls, path):
        config_path = Path(path)
        config = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
        database_config = yaml.safe_load(resolve_local_path(config["db_config_path"]).read_text(encoding="utf-8")) or {}
        return cls(config.get("memory", {}), database_config)

    def for_user(self, user_id):
        user_id = str(user_id or "").strip() or self.user_id
        if user_id == self.user_id:
            return self
        return type(self)({**self._memory_config, "user_id": user_id}, self._database_config)

    @staticmethod
    def now():
        return datetime.now(timezone.utc)

    def remember_user(self, user_text, profile_update=None):
        if not self.enabled:
            return
        recorded_at = self.now()
        self.append_event("user", user_text, recorded_at)
        self.profile.promote_facts(user_text, profile_update=profile_update, request_id=CURRENT_REQUEST_ID.get())

    def remember_assistant(self, answer):
        if self.enabled and answer:
            self.append_event("assistant", answer, self.now())

    def append_event(self, role, text, recorded_at):
        db_operations.append_conversation_entry(
            self.redis_config,
            self.user_id,
            {
                "id": uuid.uuid4().hex,
                "recorded_at_ms": int(recorded_at.timestamp() * 1000),
                "role": role,
                "text": text.strip(),
                "source": "conversation",
                "request_id": CURRENT_REQUEST_ID.get(),
                "schema_version": 4,
            },
            self.max_events,
        )

    def record_model_event(self, event_type, payload):
        event_payload = dict(payload)
        if CURRENT_REQUEST_ID.get() and "request_id" not in event_payload:
            event_payload["request_id"] = CURRENT_REQUEST_ID.get()
        db_operations.append_model_event(
            self.redis_config,
            {"t": int(self.now().timestamp()), "type": event_type, "payload": event_payload},
            self.max_model_events,
        )

    def record_model_error(self, event_type, message):
        self.record_model_event(event_type, {"error": message})

    def recent_events(self, limit):
        return db_operations.load_memory_events(self.redis_config, self.user_id, limit)

    def model_events(self, limit):
        return db_operations.load_model_events(self.redis_config, limit)

    def context(self, include_profile=True, include_required=True, include_forgotten=True):
        lines = ["MEMORY_POLICY: Treat user memory as reported context, not certain truth. Do not infer missing personal facts."]
        if include_profile:
            lines.extend(self.profile.context_lines(include_required=include_required, include_forgotten=include_forgotten))
        recent = []
        chars = 0
        forgotten_terms = self.profile.forgotten_terms()
        for event in reversed(self.recent_events(self.max_context_events)):
            text = str(event.get("txt", event.get("text", ""))).strip()
            if forgotten_terms and any(term in text.lower() for term in forgotten_terms):
                continue
            if len(text) > self.max_context_event_item_chars:
                text = text[: self.max_context_event_item_chars] + "..."
            line = f"- {event.get('role', 'user')}: {text}"
            if recent and chars + len(line) > self.max_context_event_chars:
                break
            recent.append(line)
            chars += len(line)
        if recent:
            lines.append("Recent conversation events:")
            lines.extend(reversed(recent))
        return "\n".join(lines)
