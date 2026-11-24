"""Slack entrypoint: verify signatures and route into isolated Azure Service Bus queues."""
import json
import logging
import os
import urllib.parse
import azure.functions as func
from azure.servicebus import ServiceBusClient, ServiceBusMessage
from common.clients import credential, secret_json, container
from common.slack import verify_signature
from common.contracts import is_authorized
from common.store import get

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


def _send_queue(queue_env, payload):
    with ServiceBusClient(
        fully_qualified_namespace=os.environ["ServiceBusConnection__fullyQualifiedNamespace"],
        credential=credential(),
    ) as servicebus:
        with servicebus.get_queue_sender(queue_name=os.environ[queue_env]) as sender:
            sender.send_messages(ServiceBusMessage(json.dumps(payload)))


def _json_response(code, body):
    return func.HttpResponse(json.dumps(body), status_code=code, mimetype="application/json")


def _handle_request(req, interaction=False):
    raw = req.get_body()
    try:
        signing = secret_json(os.environ["SLACK_VAULT_URL"])["signing_secret"]
        if not verify_signature(raw, dict(req.headers), signing):
            return _json_response(401, {"text": "Invalid Slack signature"})
        form = urllib.parse.parse_qs(raw.decode("utf-8"), keep_blank_values=True)
        data = {k: v[0] for k, v in form.items()}
        if interaction:
            payload = json.loads(data.get("payload", "{}"))
            if payload.get("team", {}).get("id") != os.environ["SLACK_WORKSPACE_ID"]:
                return _json_response(403, {"text": "Workspace not authorized"})
            action = (payload.get("actions") or [{}])[0]
            if action.get("action_id") not in {"defect_confirm", "defect_cancel"}:
                return _json_response(400, {"text": "Unsupported action"})
            _send_queue("ACTION_QUEUE_NAME", {
                "action": action["action_id"],
                "proposal_id": action.get("value", ""),
                "user_id": payload.get("user", {}).get("id", ""),
                "response_url": payload.get("response_url", ""),
            })
            return _json_response(200, {"response_type": "ephemeral", "text": "Action received"})

        if data.get("team_id") != os.environ["SLACK_WORKSPACE_ID"]:
            return _json_response(403, {"response_type": "ephemeral", "text": "Workspace not authorized"})
        command, user_id = data.get("command"), data.get("user_id", "")
        if command not in {"/asset-agent", "/defect-agent"}:
            return _json_response(400, {"text": "Unsupported command"})
        if command == "/defect-agent":
            if not is_authorized(get(container("AUTH_CONTAINER"), user_id)):
                return _json_response(200, {"response_type": "ephemeral", "text": "You are not authorized"})
        _send_queue("ASSET_QUEUE_NAME" if command == "/asset-agent" else "DEFECT_QUEUE_NAME", {
            "kind": "command", "command": command,
            "text": data.get("text", "").strip(), "user_id": user_id,
            "channel_id": data.get("channel_id", ""),
            "team_id": data.get("team_id", ""),
            "response_url": data.get("response_url", ""),
        })
        return _json_response(200, {"response_type": "ephemeral", "text": f"{command} request accepted for processing"})
    except Exception:
        logging.exception("Slack ingress failed")
        return _json_response(500, {"response_type": "ephemeral", "text": "Could not process request"})


@app.route(route="slack/commands", methods=["POST"])
def slack_commands(req: func.HttpRequest) -> func.HttpResponse:
    return _handle_request(req, interaction=False)


@app.route(route="slack/interactions", methods=["POST"])
def slack_interactions(req: func.HttpRequest) -> func.HttpResponse:
    return _handle_request(req, interaction=True)
