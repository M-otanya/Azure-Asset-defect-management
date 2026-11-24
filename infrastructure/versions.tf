terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # Local state for the first guided deployment. Do NOT commit terraform.tfstate.
  # Migrate to Azure Blob remote state before CI or team collaboration.
}
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
