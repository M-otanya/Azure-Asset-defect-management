"""Only this isolated Function App can read Jira write credentials and apply updates."""
import json
import logging
import os
import time
import azure.functions as func
from common.clients import container, secret_json
from common.contracts import is_authorized
from common.store import get, transition
from common.slack import respond
from common.jira import request_jira

app = func.FunctionApp()


def process(event):
    user_id, action = event.get("user_id", ""), event.get("action")
    response_url, proposal_id = event.get("response_url", ""), event.get("proposal_id", "")
    if not is_authorized(get(container("AUTH_CONTAINER"), user_id)):
        respond(response_url, {"response_type": "ephemeral", "text": "Not authorized; Jira unchanged"})
        return "DENIED"
    if action not in {"defect_confirm", "defect_cancel"} or not proposal_id:
        return "DENIED"
    proposals = container("PROPOSAL_CONTAINER")
    original = get(proposals, proposal_id)
    if not original or original.get("status") != "PENDING":
        respond(response_url, {"response_type": "ephemeral", "text": "Proposal missing or already handled"})
        return "IGNORED"
    now = int(time.time())
    if action == "defect_cancel":
        cancelled = transition(proposals, proposal_id, "PENDING", "CANCELLED",
                               {"decided_by": user_id, "decided_at": now})
        if cancelled:
            respond(response_url, {"response_type": "ephemeral", "text": "Proposal cancelled; Jira unchanged"})
        return "CANCELLED" if cancelled else "IGNORED"
    # Atomically claim the pending proposal BEFORE making any Jira write.
    claimed = transition(proposals, proposal_id, "PENDING", "APPLYING",
                         {"decided_by": user_id, "decided_at": now})
    if not claimed:
        return "IGNORED"
    fields = {"priority": {"name": claimed["priority_name"]}}
    if claimed.get("assignee_account_id"):
        fields["assignee"] = {"accountId": claimed["assignee_account_id"]}
    try:
        credential = secret_json(os.environ["JIRA_WRITE_VAULT_URL"])
        if not claimed["issue_key"].startswith(credential["project_key"].upper() + "-"):
            raise ValueError("Jira project not authorized by write credential")
        request_jira(credential, "issue/" + claimed["issue_key"], fields=fields)
        transition(proposals, proposal_id, "APPLYING", "APPLIED", {"applied_at": int(time.time())})
        respond(response_url, {"response_type": "ephemeral", "text": f"Applied proposal to {claimed['issue_key']}"})
        return "APPLIED"
    except Exception as exc:
        transition(proposals, proposal_id, "APPLYING", "FAILED", {"failure_reason": str(exc)[:400]})
        try:
            respond(response_url, {"response_type": "ephemeral", "text": f"Jira update failed for {claimed['issue_key']}; status FAILED"})
        except Exception:
            logging.exception("Could not notify Slack of Jira failure")
        logging.exception("Jira update failed")
        # Do not retry a possibly-applied write. The failed proposal needs investigation.
        return "FAILED"


@app.service_bus_queue_trigger(arg_name="msg", queue_name="%ACTION_QUEUE_NAME%", connection="ServiceBusConnection")
def jira_executor(msg: func.ServiceBusMessage):
    process(json.loads(msg.get_body().decode("utf-8")))
