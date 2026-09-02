"""Encryption helpers for the KAIROS input cache.

Cache files are stored with anonymized names (User_<hash>_<hash>.md) and their
contents are AES-256-GCM encrypted with a local key file so that the staging
area never exposes user text or user identity at rest.
"""
import base64
import hashlib
import hmac
import os
from pathlib import Path

from src.model.utils.paths import resolve_local_path

MAGIC = b"CATC1"
KEY_FILENAME = "input_cache.key"
REDIS_MAGIC = b"CATA1"


def _key_path(project_root):
    return Path(project_root) / "db" / KEY_FILENAME


def _load_or_create_key(project_root):
    path = _key_path(project_root)
    if path.exists():
        return path.read_bytes()
    path.parent.mkdir(parents=True, exist_ok=True)
    key = os.urandom(32)
    path.write_bytes(key)
    try:
        path.chmod(0o600)
    except OSError:
        pass
    return key


def _redis_key_path(redis_config):
    return resolve_local_path(redis_config.get("encryption", {}).get("key_file", "db/user_data_aes.key"))


def _redis_key(redis_config):
    path = _redis_key_path(redis_config)
    if path.exists():
        return path.read_bytes()
    path.parent.mkdir(parents=True, exist_ok=True)
    key = os.urandom(32)
    path.write_bytes(key)
    try:
        path.chmod(0o600)
    except OSError:
        pass
    return key


def _aesgcm(key):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    return AESGCM(key)


def redis_encryption_enabled(redis_config):
    return bool(redis_config.get("encryption", {}).get("enabled", False))


def protected_user_id(redis_config, user_id):
    if not redis_encryption_enabled(redis_config):
        return str(user_id)
    return "aes_" + hmac.new(_redis_key(redis_config), str(user_id).encode("utf-8"), hashlib.sha256).hexdigest()


def encrypt_redis_value(redis_config, value):
    value = str(value)
    if not redis_encryption_enabled(redis_config):
        return value
    nonce = os.urandom(12)
    ciphertext = _aesgcm(_redis_key(redis_config)).encrypt(nonce, value.encode("utf-8"), REDIS_MAGIC)
    return "CATA1:" + base64.urlsafe_b64encode(nonce + ciphertext).decode("ascii")


def decrypt_redis_value(redis_config, value):
    value = str(value)
    if not value.startswith("CATA1:"):
        return value
    raw = base64.urlsafe_b64decode(value[6:].encode("ascii"))
    return _aesgcm(_redis_key(redis_config)).decrypt(raw[:12], raw[12:], REDIS_MAGIC).decode("utf-8")


def encrypt_text(project_root, text):
    key = _load_or_create_key(project_root)
    nonce = os.urandom(12)
    ciphertext = _aesgcm(key).encrypt(nonce, text.encode("utf-8"), MAGIC)
    return MAGIC + nonce + ciphertext


def decrypt_text(project_root, data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    raw = bytes(data)
    if not raw.startswith(MAGIC):
        # Legacy plaintext cache files: pass through for one-time migration reads.
        return raw.decode("utf-8", errors="replace")
    key = _load_or_create_key(project_root)
    nonce = raw[len(MAGIC) : len(MAGIC) + 12]
    ciphertext = raw[len(MAGIC) + 12 :]
    return _aesgcm(key).decrypt(nonce, ciphertext, MAGIC).decode("utf-8")
