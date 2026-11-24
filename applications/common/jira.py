"""Jira Cloud scoped API tokens, matching AWS credential payload format."""
import json
import urllib.parse
import urllib.request
import urllib.error


def request_jira(credential, path, fields=None):
    base = f"https://api.atlassian.com/ex/jira/{urllib.parse.quote(credential['cloud_id'], safe='')}/rest/api/3/"
    url = base + path
    headers = {"authorization": f"Bearer {credential['api_token']}", "accept": "application/json"}
    data, method = None, "GET"
    if fields is not None:
        method = "PUT"
        data = json.dumps({"fields": fields}).encode("utf-8")
        headers["content-type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=12) as result:
            body = result.read().decode("utf-8")
            return json.loads(body) if body else None
    except urllib.error.HTTPError as err:
        reason = err.read(400).decode("utf-8", errors="replace")
        # Never include the token or full authorization header in errors.
        raise RuntimeError(f"Jira HTTP {err.code}: {reason[:300]}") from err
