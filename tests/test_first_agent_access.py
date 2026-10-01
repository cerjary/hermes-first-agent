import asyncio
import importlib.util
import inspect
import json
import pathlib
import tempfile
import types
import unittest


PLUGIN = (
    pathlib.Path(__file__).resolve().parents[1]
    / "plugins"
    / "first-agent-access"
    / "__init__.py"
)
SPEC = importlib.util.spec_from_file_location("first_agent_access", PLUGIN)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class _Adapter:
    def __init__(self, success=True):
        self.messages = []
        self.success = success

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        del reply_to, metadata
        self.messages.append((chat_id, content))
        return types.SimpleNamespace(
            success=self.success,
            error=None if self.success else "test delivery failure",
        )


class _PairingStore:
    def __init__(self):
        self.approved = set()
        self.pending = {}

    def is_approved(self, platform, user_id):
        return (platform, user_id) in self.approved

    def generate_code(self, platform, user_id, user_name):
        del user_name
        self.pending[platform] = user_id
        return "PAIR123"

    def approve_code(self, platform, code):
        if code != "PAIR123" or platform not in self.pending:
            return False
        self.approved.add((platform, self.pending.pop(platform)))
        return True


class _Gateway:
    def __init__(self, adapter=None, store=None):
        self.adapter = adapter or _Adapter()
        self.store = store or _PairingStore()

    def _delivery_adapter_for(self, source):
        del source
        return self.adapter

    def _pairing_store_for(self, source):
        del source
        return self.store


def _source(platform="line", chat_type="dm", user_id="U-test"):
    return types.SimpleNamespace(
        platform=types.SimpleNamespace(value=platform),
        chat_type=chat_type,
        user_id=user_id,
        user_name="Tester",
        chat_id=user_id,
    )


def _event(text="Hi", platform="line", chat_type="dm", user_id="U-test"):
    return types.SimpleNamespace(
        internal=False,
        source=_source(platform, chat_type, user_id),
        text=text,
    )


class CompanyPasscodeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state_path = pathlib.Path(self.tmp.name) / "first-agent-access.json"
        self.original_state_path = MODULE._state_path
        self.original_get_secret = MODULE._get_secret
        MODULE._state_path = lambda: self.state_path

        self.salt = "00112233445566778899aabbccddeeff"
        self.iterations = 1000
        self.passcode = "CompanyPass"
        self.expected_hash = MODULE._derive_passcode_hash(
            self.passcode, self.salt, self.iterations
        )
        values = {
            "FIRST_AGENT_ACCESS_MODE": "passcode",
            "FIRST_AGENT_PASSCODE_SALT": self.salt,
            "FIRST_AGENT_PASSCODE_HASH": self.expected_hash,
            "FIRST_AGENT_PASSCODE_ITERATIONS": str(self.iterations),
        }
        MODULE._get_secret = lambda name, default="": values.get(name, default)

    def tearDown(self):
        MODULE._state_path = self.original_state_path
        MODULE._get_secret = self.original_get_secret
        self.tmp.cleanup()

    def test_pre_gateway_dispatch_is_async(self):
        self.assertTrue(inspect.iscoroutinefunction(MODULE._pre_gateway_dispatch))

    def test_hash_round_trip(self):
        self.assertTrue(
            MODULE._verify_passcode_values(
                self.passcode, self.salt, self.expected_hash, self.iterations
            )
        )
        self.assertFalse(
            MODULE._verify_passcode_values(
                "wrong-pass", self.salt, self.expected_hash, self.iterations
            )
        )

    def test_hash_is_case_sensitive(self):
        self.assertFalse(
            MODULE._verify_passcode_values(
                "companypass", self.salt, self.expected_hash, self.iterations
            )
        )

    def test_first_dm_prompts_without_counting_failure(self):
        gateway = _Gateway()
        result = asyncio.run(
            MODULE._pre_gateway_dispatch(event=_event("Hi"), gateway=gateway)
        )
        self.assertEqual(result["reason"], "first-agent-access-passcode-required")
        self.assertEqual(len(gateway.adapter.messages), 1)
        self.assertIn("Enter the Company Access Passcode", gateway.adapter.messages[0][1])
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        entry = state["line:U-test"]
        self.assertTrue(entry["awaiting_passcode"])
        self.assertEqual(entry["failures"], [])
        self.assertEqual(entry["locked_until"], 0.0)

    def test_second_wrong_message_counts_one_failure(self):
        gateway = _Gateway()
        asyncio.run(MODULE._pre_gateway_dispatch(event=_event("Hi"), gateway=gateway))
        result = asyncio.run(
            MODULE._pre_gateway_dispatch(event=_event("wrong-pass"), gateway=gateway)
        )
        self.assertEqual(result["reason"], "first-agent-access-passcode-invalid")
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(len(state["line:U-test"]["failures"]), 1)
        self.assertEqual(
            gateway.adapter.messages[-1][1],
            "Passcode incorrect. Please try again.",
        )

    def test_correct_passcode_approves_and_clears_transient_state(self):
        gateway = _Gateway()
        asyncio.run(MODULE._pre_gateway_dispatch(event=_event("Hi"), gateway=gateway))
        result = asyncio.run(
            MODULE._pre_gateway_dispatch(event=_event(self.passcode), gateway=gateway)
        )
        self.assertEqual(result["reason"], "first-agent-access-approved")
        self.assertTrue(gateway.store.is_approved("line", "U-test"))
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertNotIn("line:U-test", state)
        self.assertIn("Access verified", gateway.adapter.messages[-1][1])

    def test_legacy_failure_state_is_reset_to_first_prompt(self):
        self.state_path.write_text(
            json.dumps(
                {
                    "line:U-test": {
                        "failures": [1.0, 2.0, 3.0],
                        "locked_until": 9999999999.0,
                    }
                }
            ),
            encoding="utf-8",
        )
        gateway = _Gateway()
        result = asyncio.run(
            MODULE._pre_gateway_dispatch(event=_event("Hi"), gateway=gateway)
        )
        self.assertEqual(result["reason"], "first-agent-access-passcode-required")
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["line:U-test"]["failures"], [])
        self.assertEqual(state["line:U-test"]["locked_until"], 0.0)
        self.assertTrue(state["line:U-test"]["awaiting_passcode"])

    def test_line_group_is_blocked_in_passcode_mode(self):
        gateway = _Gateway()
        result = asyncio.run(
            MODULE._pre_gateway_dispatch(
                event=_event("Hi", chat_type="group", user_id="C-test"),
                gateway=gateway,
            )
        )
        self.assertEqual(result["reason"], "first-agent-access-line-non-dm")
        self.assertEqual(gateway.adapter.messages, [])
        self.assertFalse(self.state_path.exists())

    def test_send_failure_is_observable_to_caller(self):
        gateway = _Gateway(adapter=_Adapter(success=False))
        ok = asyncio.run(MODULE._send(gateway, _source(), "test"))
        self.assertFalse(ok)


if __name__ == "__main__":
    unittest.main()
