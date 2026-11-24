"""Authorize an immutable Slack user ID in the Azure Cosmos defect-authorization container.

Usage: python scripts/authorize-user.py U0123456789
Requires: az login; pip install -r scripts/requirements.txt; terraform apply already completed.
"""
import argparse
import json
import pathlib
import subprocess
from azure.cosmos import CosmosClient
from azure.identity import AzureCliCredential

ROOT = pathlib.Path(__file__).resolve().parent.parent
INFRA = ROOT / "infrastructure"


def tf_output(name):
    return subprocess.check_output(
        ["terraform", f"-chdir={INFRA}", "output", "-raw", name], text=True
    ).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("slack_user_id", help="Slack member ID, e.g. U0123456789")
    parser.add_argument("--role", choices=("defect_operator", "defect_admin"), default="defect_operator")
    parser.add_argument("--disable", action="store_true")
    args = parser.parse_args()
    if not args.slack_user_id.startswith(("U", "W")):
        parser.error("Slack member ID normally starts with U or W")
    c = CosmosClient(tf_output("cosmos_endpoint"), credential=AzureCliCredential())
    table = c.get_database_client(tf_output("cosmos_database")).get_container_client(
        tf_output("cosmos_authorization_container"))
    row = {"id": args.slack_user_id, "enabled": not args.disable, "role": args.role}
    table.upsert_item(row)
    print("Slack operator authorization updated:", args.slack_user_id, row["enabled"], row["role"])


if __name__ == "__main__":
    main()
