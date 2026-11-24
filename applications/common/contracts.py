"""Pure validation logic; testable without Azure or Jira credentials."""
import re

_ALLOWED_PRIORITIES = {p.lower(): p for p in ("Highest", "High", "Medium", "Low", "Lowest")}


def parse_defect_command(text):
    m = re.search(r"\b([A-Z][A-Z0-9]+-\d+)\b", text.upper())
    priority = re.search(r"\bpriority\s*=\s*([^\s]+)", text, re.IGNORECASE)
    assignee = re.search(r"\bassignee\s*=\s*([^\s]+)", text, re.IGNORECASE)
    if not m:
        raise ValueError("Use: /defect-agent SCRUM-5 priority=High assignee=<jira-account-id>")
    requested = priority.group(1) if priority else "Medium"
    normalized = _ALLOWED_PRIORITIES.get(requested.lower())
    if not normalized:
        raise ValueError("Priority must be Highest, High, Medium, Low, or Lowest (or adapt the project's allowed list).")
    return m.group(1), normalized, assignee.group(1) if assignee else ""


def slack_escape(value):
    return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def is_authorized(document):
    return (bool(document) and document.get("enabled") is True
            and document.get("role") in {"defect_operator", "defect_admin"})
