"""Slack request verification and response_url messages."""
import hashlib
import hmac
import json
import time
import urllib.request


def verify_signature(raw_body, headers, signing_secret, now=None):
    lower = {key.lower(): value for key, value in headers.items()}
    ts, sig = lower.get("x-slack-request-timestamp", ""), lower.get("x-slack-signature", "")
    try:
        timestamp = int(ts)
    except (ValueError, TypeError):
        return False
    if abs((now if now is not None else time.time()) - timestamp) > 300:
        return False
    basestring = b"v0:" + str(timestamp).encode() + b":" + raw_body
    expected = "v0=" + hmac.new(signing_secret.encode(), basestring, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, sig)


def respond(response_url, payload):
    if not response_url:
        return
    # Slack supplies this short-lived URL in its already-verified signed payload.
    if not response_url.startswith("https://hooks.slack.com/"):
        raise ValueError("Unexpected Slack response_url host")
    req = urllib.request.Request(
        response_url, data=json.dumps(payload).encode("utf-8"),
        headers={"content-type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=8):
        pass
