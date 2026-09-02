import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import yaml


@dataclass
class Usage:
    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0


@dataclass
class DeepSeekResponse:
    text: str
    model: str
    usage: Usage
    raw: dict


class DeepSeekClient:
    def __init__(self, config_path):
        config_path = Path(config_path).resolve()
        config = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
        self.settings = config.get("model", config)
        self._retried = False
        self.project_root = next(
            (parent for parent in (config_path.parent, *config_path.parents) if (parent / "data").exists()),
            Path.cwd(),
        )

    def complete(self, prompt, max_tokens=None, include_system_prompt=True):
        messages = [{"role": "user", "content": prompt}]
        system = self.system_prompt() if include_system_prompt else ""
        if system:
            messages.insert(0, {"role": "system", "content": system})
        return self.complete_messages(messages, max_tokens=max_tokens)

    def stream(self, prompt, max_tokens=None, include_system_prompt=True):
        messages = [{"role": "user", "content": prompt}]
        system = self.system_prompt() if include_system_prompt else ""
        if system:
            messages.insert(0, {"role": "system", "content": system})
        return self.stream_messages(messages, max_tokens=max_tokens)

    def system_prompt(self):
        system_path = self.settings.get("system_path")
        if not self.settings.get("include_system_prompt", True) or not system_path:
            return ""
        system_file = Path(system_path)
        if not system_file.is_absolute():
            system_file = self.project_root / system_file
        return system_file.read_text(encoding="utf-8").strip()

    def complete_messages(self, messages, max_tokens=None):
        timeout = float(self.settings.get("timeout_seconds", 120))
        request = self._request(messages, max_tokens=max_tokens, stream=False)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError) as exc:
            # One retry for transient transport stalls (read timeouts, resets).
            if self._retried:
                raise
            self._retried = True
            time.sleep(2)
            request = self._request(messages, max_tokens=max_tokens, stream=False)
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = json.loads(response.read().decode("utf-8"))
            self._retried = False
        message = ((raw.get("choices") or [{}])[0].get("message") or {})
        usage = raw.get("usage") or {}
        return DeepSeekResponse(
            text=str(message.get("content") or ""),
            model=str(raw.get("model") or self.settings.get("name") or ""),
            usage=Usage(
                prompt_tokens=int(usage.get("prompt_tokens") or 0),
                completion_tokens=int(usage.get("completion_tokens") or 0),
                total_tokens=int(usage.get("total_tokens") or 0),
            ),
            raw=raw,
        )

    def stream_messages(self, messages, max_tokens=None):
        request = self._request(messages, max_tokens=max_tokens, stream=True)
        model = str(self.settings.get("name") or "")
        with urllib.request.urlopen(request, timeout=float(self.settings.get("timeout_seconds", 120))) as response:
            for raw_line in response:
                line = raw_line.decode("utf-8").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                event = json.loads(data)
                model = str(event.get("model") or model)
                choice = (event.get("choices") or [{}])[0]
                delta = choice.get("delta") or {}
                yield {
                    "text": str(delta.get("content") or ""),
                    "model": model,
                    "usage": event.get("usage") or {},
                    "finish_reason": choice.get("finish_reason"),
                }

    def _request(self, messages, max_tokens=None, stream=False):
        settings = self.settings
        model_env = str(settings.get("model_env", "")).strip()
        api_key_setting = str(settings.get("api_key_env", "")).strip()
        extra_body_env = str(settings.get("extra_body_env", "")).strip()
        payload = {
            "model": os.getenv(model_env) or settings.get("name"),
            "messages": messages,
            "stream": stream,
            "temperature": settings.get("temperature", 0.0),
            "top_p": settings.get("top_p", 1.0),
            "parallel_tool_calls": False,
        }
        if max_tokens is not None:
            payload["max_tokens"] = int(max_tokens)
        elif settings.get("max_tokens"):
            payload["max_tokens"] = int(settings["max_tokens"])
        if settings.get("reasoning_effort"):
            payload["reasoning_effort"] = settings["reasoning_effort"]
        if stream:
            payload["stream_options"] = {"include_usage": True}
        extra_body = settings.get("extra_body", {}) or {}
        if extra_body_env and os.getenv(extra_body_env):
            extra_body = {**extra_body, **json.loads(os.environ[extra_body_env])}
        payload.update(extra_body)
        payload["parallel_tool_calls"] = False

        base_url_env = str(settings.get("base_url_env", "")).strip()
        base_url = os.getenv(base_url_env) or settings["base_url"]
        api_key = os.getenv(api_key_setting) or os.getenv("CLOUD_BACKBONE_API_KEY") or api_key_setting
        request = urllib.request.Request(
            base_url,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
                "User-Agent": settings.get("user_agent", "cat-tone"),
            },
            method="POST",
        )
        return request
