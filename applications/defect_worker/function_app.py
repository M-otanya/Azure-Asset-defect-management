"""Read-only Jira worker. Proposes a change; does not have Jira write credentials."""
import json
import logging
import os
import time
import uuid
import urllib.parse
import azure.functions as func
from common.clients import container, secret_json
from common.contracts import parse_defect_command, slack_escape
from common.store import create
from common.slack import respond
from common.jira import request_jira
from common.ai_review import assess

app = func.FunctionApp()


def process(request):
    issue_key, priority, assignee = parse_defect_command(request.get("text", ""))
    jira = secret_json(os.environ["JIRA_READ_VAULT_URL"])
    if not issue_key.startswith(jira["project_key"].upper() + "-"):
        raise ValueError(f"Only {jira['project_key']} issues are allowed")
    issue = request_jira(jira, "issue/" + urllib.parse.quote(issue_key) + "?fields=summary,status,priority,assignee")
    fields = issue.get("fields", {})
    proposal_id, now = str(uuid.uuid4()), int(time.time())
    risk = assess(issue_key, fields, priority, assignee)
    proposal = {
        "id": proposal_id, "issue_key": issue_key,
        "issue_summary": fields.get("summary", ""),
        "current_status": (fields.get("status") or {}).get("name", "Unknown"),
        "current_priority": (fields.get("priority") or {}).get("name", "Unknown"),
        "requested_by": request["user_id"],
        "priority_name": priority, "assignee_account_id": assignee,
        "ai_status": risk["review_status"], "risk_level": risk["risk_level"],
        "risk_rationale": risk["risk_rationale"],
        "human_confirmation_required": True, "status": "PENDING", "created_at": now,
    }
    create(container("PROPOSAL_CONTAINER"), proposal)
    create(container("EVENT_CONTAINER"), {
        "id": str(uuid.uuid4()), "proposal_id": proposal_id,
        "event_type": "DEFECT_PROPOSAL_CREATED", "ai_status": risk["review_status"],
        "risk_level": risk["risk_level"], "created_at": now, "ttl": 2592000,
    })
    assignee_line = f"\n• Proposed assignee: `{slack_escape(assignee)}`" if assignee else ""
    text = (
        f"*{slack_escape(issue_key)}: {slack_escape(proposal['issue_summary'])}*\n"
        f"• Status: {slack_escape(proposal['current_status'])}\n"
        f"• Priority: {slack_escape(proposal['current_priority'])} → *{slack_escape(priority)}*"
        f"{assignee_line}\n\n*AI risk: {risk['risk_level']}*\n"
        f"{slack_escape(risk['risk_rationale'])}\n\n"
        "This assessment is advisory. Confirm or cancel the proposal below."
    )
    respond(request.get("response_url", ""), {
        "response_type": "ephemeral", "text": f"Review proposal for {issue_key}",
        "blocks": [
            {"type": "section", "text": {"type": "mrkdwn", "text": text}},
            {"type": "actions", "elements": [
                {"type": "button", "text": {"type": "plain_text", "text": "Confirm"},
                 "style": "primary", "action_id": "defect_confirm", "value": proposal_id},
                {"type": "button", "text": {"type": "plain_text", "text": "Cancel"},
                 "action_id": "defect_cancel", "value": proposal_id},
            ]},
        ],
    })
    logging.info("Created proposal %s for %s", proposal_id, issue_key)


@app.service_bus_queue_trigger(arg_name="msg", queue_name="%DEFECT_QUEUE_NAME%", connection="ServiceBusConnection")
def defect_worker(msg: func.ServiceBusMessage):
    request = json.loads(msg.get_body().decode("utf-8"))
    try:
        process(request)
    except Exception as exc:
        logging.exception("Defect proposal failed")
        try:
            respond(request.get("response_url", ""), {
                "response_type": "ephemeral", "text": f"Defect request failed: {str(exc)[:200]}"
            })
        except Exception:
            logging.exception("Could not notify Slack of worker failure")
        raise  # Service Bus retries and dead-letters after max_delivery_count.
