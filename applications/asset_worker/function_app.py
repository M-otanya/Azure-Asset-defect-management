"""Asset request recorder; source AWS project intentionally leaves asset AI integration pending."""
import json
import logging
import time
import uuid
import azure.functions as func
from common.clients import container
from common.store import create
from common.slack import respond

app = func.FunctionApp()


@app.service_bus_queue_trigger(arg_name="msg", queue_name="%ASSET_QUEUE_NAME%", connection="ServiceBusConnection")
def asset_worker(msg: func.ServiceBusMessage):
    request = json.loads(msg.get_body().decode("utf-8"))
    now, session_id = int(time.time()), str(uuid.uuid4())
    create(container("SESSION_CONTAINER"), {
        "id": session_id, "slack_user_id": request["user_id"],
        "request_text": request.get("text", ""), "status": "RECEIVED",
        "created_at": now, "ttl": 86400,
    })
    create(container("EVENT_CONTAINER"), {
        "id": str(uuid.uuid4()), "session_id": session_id,
        "event_type": "ASSET_REQUEST_RECEIVED", "created_at": now, "ttl": 604800,
    })
    respond(request.get("response_url", ""), {
        "response_type": "ephemeral", "text": (
            f"Asset request `{session_id}` recorded. Asset AI execution remains a future phase, "
            "as in the source AWS project."
        ),
    })
    logging.info("Recorded asset request %s", session_id)
