terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Fill these from scripts/bootstrap-backend.ps1 output, then run `terraform init`.
  backend "azurerm" {
    resource_group_name  = "rg-llmgw-tfstate-dev-eastus2"
    storage_account_name = "stllmgwtfstateuuen0t"
    container_name       = "tfstate"
    key                  = "llm-gateway-eus2.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  storage_use_azuread = true
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
    resource_group {
      prevent_deletion_if_contains_resources = false # demo/teaching env: allow destroy even if RG has untracked resources
    }
  }
}

provider "azapi" {}
