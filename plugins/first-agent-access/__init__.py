"""Profile-scoped Company Access Passcode gate for Hermes First Agent."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import secrets
import threading
import time
from pathlib import Path
from typing import Any

FAIL_WINDOW_SECONDS = 15 * 60
LOCK_SECONDS = 15 * 60
MAX_FAILURES = 5
_STATE_LOCK = threading.RLock()
logger = logging.getLogger(__name__)

_PASSCODE_PROMPT = (
    "This Company AI Advisor is for authorized company users. "
    "Enter the Company Access Passcode to continue."
)


def _get_secret(name: str, default: str = "") -> str:
    try:
        from gateway.platforms._shared import get_scoped_secret
        value = get_scoped_secret(name, default)
    except Exception:
        value = os.getenv(name, default)
    return str(value or default).strip()


def _derive_passcode_hash(passcode: str, salt_hex: str, iterations: int) -> str:
    salt = bytes.fromhex(salt_hex)
    return hashlib.pbkdf2_hmac(
        "sha256", passcode.encode("utf-8"), salt, int(iterations)
    ).hex()


def _verify_passcode_values(
    candidate: str, salt_hex: str, expected_hash: str, iterations: int
) -> bool:
    try:
        actual = _derive_passcode_hash(candidate, salt_hex, iterations)
    except (TypeError, ValueError):
        return False
    return secrets.compare_digest(actual, expected_hash)


def _passcode_matches(candidate: str) -> bool:
    salt = _get_secret("FIRST_AGENT_PASSCODE_SALT")
    expected = _get_secret("FIRST_AGENT_PASSCODE_HASH")
    raw_iterations = _get_secret("FIRST_AGENT_PASSCODE_ITERATIONS", "210000")
    if not salt or not expected:
        return False
    try:
        iterations = int(raw_iterations)
    except ValueError:
        return False
    return _verify_passcode_values(candidate, salt, expected, iterations)


def _hermes_home() -> Path:
    try:
        from hermes_constants import get_hermes_home
        return Path(get_hermes_home()).expanduser().resolve()
    except Exception:
        return Path(
            os.getenv("HERMES_HOME", str(Path.home() / ".hermes"))
        ).expanduser().resolve()


def _state_path() -> Path:
    return _hermes_home() / "runtime" / "first-agent-access.json"


def _read_state() -> dict[str, Any]:
    path = _state_path()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _write_state(data: dict[str, Any]) -> None:
    path = _state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, sort_keys=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _principal_key(platform: str, user_id: str) -> str:
    return f"{platform}:{user_id}"


def _needs_initial_prompt(platform: str, user_id: str) -> bool:
    """Create the awaiting-passcode state on first contact.

    Pre-v0.5.6 entries did not have awaiting_passcode and may contain failures
    caused by ordinary greeting text. Treat those entries as legacy and reset
    them so an upgrade cannot lock out an unapproved user.
    """
    key = _principal_key(platform, user_id)
    with _STATE_LOCK:
        state = _read_state()
        entry = state.get(key)
        if isinstance(entry, dict) and entry.get("awaiting_passcode") is True:
            return False
        state[key] = {
            "awaiting_passcode": True,
            "failures": [],
            "locked_until": 0.0,
        }
        _write_state(state)
        return True


def _is_locked(platform: str, user_id: str) -> bool:
    now = time.time()
    key = _principal_key(platform, user_id)
    with _STATE_LOCK:
        state = _read_state()
        entry = state.get(key)
        if not isinstance(entry, dict):
            return False
        locked_until = entry.get("locked_until", 0)
        return isinstance(locked_until, (int, float)) and locked_until > now


def _record_failure(platform: str, user_id: str) -> bool:
    """Record a failed attempt. Return True when the sender is now locked."""
    now = time.time()
    key = _principal_key(platform, user_id)
    with _STATE_LOCK:
        state = _read_state()
        entry = state.get(key) if isinstance(state.get(key), dict) else {}
        failures = [
            float(ts)
            for ts in entry.get("failures", [])
            if isinstance(ts, (int, float))
            and now - float(ts) <= FAIL_WINDOW_SECONDS
        ]
        failures.append(now)
        locked_until = float(entry.get("locked_until", 0) or 0)
        if len(failures) >= MAX_FAILURES:
            locked_until = max(locked_until, now + LOCK_SECONDS)
            failures = []
        state[key] = {
            "awaiting_passcode": True,
            "failures": failures,
            "locked_until": locked_until,
        }
        _write_state(state)
        return locked_until > now


def _clear_failures(platform: str, user_id: str) -> None:
    key = _principal_key(platform, user_id)
    with _STATE_LOCK:
        state = _read_state()
        if key in state:
            state.pop(key, None)
            _write_state(state)


async def _send(gateway: Any, source: Any, message: str) -> bool:
    """Deliver an access-control reply and make failures observable."""
    adapter = None
    try:
        adapter = gateway._delivery_adapter_for(source)
    except Exception:
        adapters = getattr(gateway, "adapters", None) or {}
        adapter = adapters.get(getattr(source, "platform", None))
    if adapter is None:
        logger.warning(
            "First Agent access reply could not be sent: no delivery adapter for %s",
            getattr(source, "platform", None),
        )
        return False

    try:
        result = await adapter.send(source.chat_id, message)
    except Exception:
        logger.warning(
            "First Agent access reply raised while sending to %s",
            getattr(source, "platform", None),
            exc_info=True,
        )
        return False

    if getattr(result, "success", True) is False:
        logger.warning(
            "First Agent access reply failed on %s: %s",
            getattr(source, "platform", None),
            getattr(result, "error", "unknown delivery error"),
        )
        return False
    return True


def _pairing_store(gateway: Any, source: Any):
    try:
        return gateway._pairing_store_for(source)
    except Exception:
        return getattr(gateway, "pairing_store", None)


def _approve_user(
    store: Any, platform: str, user_id: str, user_name: str
) -> bool:
    """Grant via Hermes PairingStore so core authorization remains the final gate."""
    if store is None:
        return False
    try:
        if store.is_approved(platform, user_id):
            return True
    except Exception:
        pass

    try:
        code = store.generate_code(platform, user_id, user_name)
        if code and store.approve_code(platform, code):
            return bool(store.is_approved(platform, user_id))
    except Exception:
        pass

    approve = getattr(store, "_approve_user", None)
    lock = getattr(store, "_lock", None)
    if callable(approve) and lock is not None:
        try:
            with lock:
                approve(platform, user_id, user_name)
            return bool(store.is_approved(platform, user_id))
        except Exception:
            return False
    return False


async def _pre_gateway_dispatch(event=None, gateway=None, **kwargs):
    del kwargs
    if event is None or gateway is None or getattr(event, "internal", False):
        return None

    if _get_secret("FIRST_AGENT_ACCESS_MODE") != "passcode":
        return None

    source = getattr(event, "source", None)
    if source is None:
        return None

    platform_obj = getattr(source, "platform", None)
    platform = str(getattr(platform_obj, "value", "") or "").strip().lower()
    chat_type = str(getattr(source, "chat_type", "") or "").strip().lower()

    # LINE passcode mode must enable adapter ingress so an unknown DM can reach
    # this hook. Do not let that transport-level switch admit LINE groups/rooms.
    if platform == "line" and chat_type != "dm":
        return {
            "action": "skip",
            "reason": "first-agent-access-line-non-dm",
        }

    # Preserve Hermes authorization behavior for non-DM traffic on platforms
    # that do not need the LINE ingress workaround.
    if chat_type != "dm":
        return None

    user_id = str(getattr(source, "user_id", "") or "").strip()
    if not platform or not user_id:
        return {
            "action": "skip",
            "reason": "first-agent-access-missing-identity",
        }

    store = _pairing_store(gateway, source)
    try:
        if store is not None and store.is_approved(platform, user_id):
            return None
    except Exception:
        pass

    # First contact is always an onboarding prompt. The greeting itself does
    # not count as a passcode attempt.
    if _needs_initial_prompt(platform, user_id):
        await _send(gateway, source, _PASSCODE_PROMPT)
        return {
            "action": "skip",
            "reason": "first-agent-access-passcode-required",
        }

    if _is_locked(platform, user_id):
        await _send(
            gateway,
            source,
            "Too many incorrect passcode attempts. Please try again in 15 minutes.",
        )
        return {"action": "skip", "reason": "first-agent-access-locked"}

    text = str(getattr(event, "text", "") or "").strip()
    if not text or text.startswith("/"):
        await _send(gateway, source, _PASSCODE_PROMPT)
        return {
            "action": "skip",
            "reason": "first-agent-access-passcode-required",
        }

    if _passcode_matches(text):
        if _approve_user(
            store,
            platform,
            user_id,
            str(getattr(source, "user_name", "") or ""),
        ):
            _clear_failures(platform, user_id)
            await _send(
                gateway,
                source,
                "Access verified. Your messaging account is now authorized "
                "for this Agent. Send your request to continue.",
            )
            return {
                "action": "skip",
                "reason": "first-agent-access-approved",
            }

        await _send(
            gateway,
            source,
            "The passcode was valid, but access could not be saved. "
            "Please contact the installer.",
        )
        return {
            "action": "skip",
            "reason": "first-agent-access-approval-failed",
        }

    locked = _record_failure(platform, user_id)
    message = (
        "Too many incorrect passcode attempts. Please try again in 15 minutes."
        if locked
        else "Passcode incorrect. Please try again."
    )
    await _send(gateway, source, message)
    return {
        "action": "skip",
        "reason": "first-agent-access-passcode-invalid",
    }


def register(ctx):
    ctx.register_hook("pre_gateway_dispatch", _pre_gateway_dispatch)
