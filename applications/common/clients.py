"""Identity-based Azure service clients. Never load cloud credentials from Terraform."""
import json
import os
from functools import lru_cache
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient
from azure.keyvault.secrets import SecretClient


@lru_cache(maxsize=1)
def credential():
    return DefaultAzureCredential(exclude_interactive_browser_credential=True)


@lru_cache(maxsize=1)
def cosmos_client():
    return CosmosClient(url=os.environ["COSMOS_ENDPOINT"], credential=credential())


def container(env_name):
    name = os.environ[env_name]
    return (cosmos_client()
            .get_database_client(os.environ["COSMOS_DATABASE"])
            .get_container_client(name))


@lru_cache(maxsize=3)
def secret_json(vault_url):
    # Secret payload matches the JSON formats used in the AWS Secrets Manager project.
    value = SecretClient(vault_url=vault_url, credential=credential()).get_secret("credentials").value
    return json.loads(value)
