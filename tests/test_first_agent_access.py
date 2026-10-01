import importlib.util
import pathlib
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


class CompanyPasscodeTests(unittest.TestCase):
    def test_hash_round_trip(self):
        salt = "00112233445566778899aabbccddeeff"
        iterations = 1000
        expected = MODULE._derive_passcode_hash(
            "nextoa-pass", salt, iterations
        )
        self.assertTrue(
            MODULE._verify_passcode_values(
                "nextoa-pass", salt, expected, iterations
            )
        )
        self.assertFalse(
            MODULE._verify_passcode_values(
                "wrong-pass", salt, expected, iterations
            )
        )

    def test_hash_is_case_sensitive(self):
        salt = "ffeeddccbbaa99887766554433221100"
        expected = MODULE._derive_passcode_hash(
            "CompanyPass", salt, 1000
        )
        self.assertFalse(
            MODULE._verify_passcode_values(
                "companypass", salt, expected, 1000
            )
        )


if __name__ == "__main__":
    unittest.main()
