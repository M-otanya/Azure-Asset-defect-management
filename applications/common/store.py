"""Cosmos NoSQL document access and conditional (ETag) workflow transitions."""
from azure.core import MatchConditions
from azure.core.exceptions import ResourceNotFoundError, ResourceModifiedError
from azure.cosmos.exceptions import CosmosResourceNotFoundError, CosmosHttpResponseError


def get(container, doc_id):
    try:
        return container.read_item(item=doc_id, partition_key=doc_id)
    except (ResourceNotFoundError, CosmosResourceNotFoundError):
        return None


def create(container, item):
    if not item.get("id"):
        raise ValueError("Document id is required")
    return container.create_item(body=item)


def transition(container, doc_id, expected, next_status, changes=None):
    """Returns the new document or None when proposal is already handled.

    The IfNotModified condition prevents two simultaneous Confirm/Cancel attempts
    from both successfully claiming the same pending proposal.
    """
    doc = get(container, doc_id)
    if not doc or doc.get("status") != expected:
        return None
    updated = dict(doc)
    updated["status"] = next_status
    updated.update(changes or {})
    try:
        return container.replace_item(
            item=doc["id"], body=updated,
            etag=doc["_etag"], match_condition=MatchConditions.IfNotModified,
        )
    except (ResourceModifiedError, CosmosHttpResponseError) as exc:
        # Conflicts are normal when two operators act at the same time.
        if getattr(exc, "status_code", None) in (409, 412):
            return None
        raise
