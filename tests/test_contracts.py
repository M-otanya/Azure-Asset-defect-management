import hashlib
import hmac
import pathlib
import sys
import time
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "applications"))
from common.contracts import parse_defect_command, is_authorized, slack_escape
from common.slack import verify_signature


class ContractTests(unittest.TestCase):
    def test_issue_priority_normalized(self):
        self.assertEqual(parse_defect_command("SCRUM-5 priority=low"), ("SCRUM-5", "Low", ""))
        self.assertEqual(parse_defect_command("scrum-5 assignee=abc priority=HIGH"),
                         ("SCRUM-5", "High", "abc"))

    def test_invalid_priority(self):
        with self.assertRaises(ValueError):
            parse_defect_command("SCRUM-5 priority=NotARealPriority")

    def test_missing_issue(self):
        with self.assertRaises(ValueError):
            parse_defect_command("priority=High")

    def test_operator_permission(self):
        self.assertTrue(is_authorized({"enabled": True, "role": "defect_operator"}))
        self.assertTrue(is_authorized({"enabled": True, "role": "defect_admin"}))
        self.assertFalse(is_authorized({"enabled": False, "role": "defect_admin"}))
        self.assertFalse(is_authorized({"enabled": True, "role": "viewer"}))
        self.assertFalse(is_authorized(None))

    def test_hmac_slack_signature(self):
        now, raw, secret = 1730000000, b"text=SCRUM-5&command=%2Fdefect-agent", "secret123"
        expected = "v0=" + hmac.new(secret.encode(), b"v0:" + str(now).encode() + b":" + raw,
                                     hashlib.sha256).hexdigest()
        headers = {"X-Slack-Request-Timestamp": str(now), "X-Slack-Signature": expected}
        self.assertTrue(verify_signature(raw, headers, secret, now=now))
        self.assertFalse(verify_signature(raw + b"tamper", headers, secret, now=now))
        self.assertFalse(verify_signature(raw, headers, secret, now=now + 301))

    def test_slack_escape(self):
        self.assertEqual(slack_escape("a<&>b"), "a&lt;&amp;&gt;b")


if __name__ == "__main__":
    unittest.main()
