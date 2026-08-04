terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0" # aligned with the chatbot project
    }
  }

  # TODO: move state to a remote backend. Local state means terraform.tfstate
  # sits unencrypted on one laptop, and it contains the Cosmos connection
  # string and the OpenAI key in plaintext.
  #
  # backend "azurerm" {
  #   resource_group_name  = "tfstate-rg"
  #   storage_account_name = "<globally unique>"
  #   container_name       = "tfstate"
  #   key                  = "llm-pipeline.tfstate"
  # }
}

provider "azurerm" {
  subscription_id = var.subscription_id # required by azurerm v4
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

variable "subscription_id" {
  description = "Azure subscription ID (required by the azurerm v4 provider)"
  type        = string
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus2"
}

variable "prefix" {
  description = <<-EOT
    Name prefix for every resource.

    Storage account, Key Vault and Cosmos DB names share a GLOBAL namespace,
    so this must be unique across all of Azure. Cloning this repo and running
    `terraform apply` with the default will fail with "name already taken" —
    set your own prefix in terraform.tfvars.
  EOT
  type        = string
  default     = "llmpipeline"

  validation {
    condition     = can(regex("^[a-z0-9]{3,17}$", var.prefix))
    error_message = "prefix must be 3-17 lowercase alphanumeric characters (storage account names allow no dashes and cap at 24)."
  }
}

variable "openai_endpoint" {
  description = "Azure OpenAI endpoint URL, stored in Key Vault for the function to read"
  type        = string
}

variable "openai_api_key" {
  description = "Azure OpenAI API key, stored in Key Vault for the function to read"
  type        = string
  sensitive   = true
}

locals {
  tags = {
    project     = var.prefix
    environment = "demo"
    managed_by  = "terraform"
  }
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "sa" {
  name                     = "${var.prefix}sa"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  # Blobs here are the function's input documents and deployment package.
  # Nothing should ever be anonymously readable.
  allow_nested_items_to_be_public = false

  tags = local.tags
}

resource "azurerm_storage_container" "input" {
  name                  = "input-documents"
  storage_account_id    = azurerm_storage_account.sa.id # v4: replaced storage_account_name
  container_access_type = "private"
}

resource "azurerm_service_plan" "plan" {
  name                = "${var.prefix}-plan"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"

  # TODO: migrate to FC1 (Flex Consumption), as the chatbot project uses.
  # Y1 is the retiring Linux Consumption SKU. This is a destroy/recreate of
  # the Function App — new hostname, redeploy required — so schedule it
  # rather than letting it happen inside an unrelated apply.
  sku_name = "Y1"

  tags = local.tags
}

# Workspace-based Application Insights. A bare azurerm_application_insights
# with no workspace_id creates a *classic* resource, and classic App Insights
# has been retired — a fresh apply of the previous config would fail.
resource "azurerm_log_analytics_workspace" "law" {
  name                = "${var.prefix}-law"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "ai" {
  name                = "${var.prefix}-insights"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
  tags                = local.tags
}

resource "azurerm_linux_function_app" "func" {
  name                       = "${var.prefix}-func"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  service_plan_id            = azurerm_service_plan.plan.id
  storage_account_name       = azurerm_storage_account.sa.name
  storage_account_access_key = azurerm_storage_account.sa.primary_access_key

  https_only = true

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.12"
    }
    application_insights_connection_string = azurerm_application_insights.ai.connection_string
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME = "python"
    # APPINSIGHTS_INSTRUMENTATIONKEY is deprecated; ingestion moved to the
    # connection string, which also carries the regional endpoint.
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.ai.connection_string
    KEY_VAULT_URL                         = azurerm_key_vault.kv.vault_uri
    AZURE_OPENAI_DEPLOYMENT               = "gpt-4o"
    COSMOS_DATABASE                       = azurerm_cosmosdb_sql_database.db.name
    COSMOS_CONTAINER                      = azurerm_cosmosdb_sql_container.container.name
  }

  tags = local.tags
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                       = "${var.prefix}-kv"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false # set true for production/compliance

  tags = local.tags
}

# ─────────────────────────────────────────────────────────
# Access policies as SEPARATE resources, not inline blocks.
#
# Inline access_policy blocks created a dependency cycle that made this
# whole config unappliable: the Function App needs the vault's URI for
# KEY_VAULT_URL, while the vault needed the Function App's managed identity
# principal ID. Terraform reported:
#
#   Error: Cycle: azurerm_linux_function_app.func, azurerm_key_vault.kv
#
# Splitting them out breaks the loop — the vault no longer references the
# function app, so the graph is: vault -> function app -> access policy.
# ─────────────────────────────────────────────────────────
resource "azurerm_key_vault_access_policy" "function_app" {
  key_vault_id       = azurerm_key_vault.kv.id
  tenant_id          = azurerm_linux_function_app.func.identity[0].tenant_id
  object_id          = azurerm_linux_function_app.func.identity[0].principal_id
  secret_permissions = ["Get", "List"] # read-only: least privilege
}

resource "azurerm_key_vault_access_policy" "user" {
  key_vault_id       = azurerm_key_vault.kv.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = data.azurerm_client_config.current.object_id
  secret_permissions = ["Get", "List", "Set", "Delete", "Purge", "Recover"]
}

# ─────────────────────────────────────────────────────────
# Key Vault secrets
#
# function_app.py calls get_secret() for all three of these. They were NOT
# defined in Terraform, so `terraform apply` produced infrastructure that
# crashed on the first blob until the secrets were added by hand.
#
# cosmos-connection-string is derived from the Cosmos account below. The two
# OpenAI values come from variables because this config does not provision the
# Azure OpenAI resource itself (see TODO at the bottom of this file).
# ─────────────────────────────────────────────────────────
resource "azurerm_key_vault_secret" "cosmos_connection" {
  name         = "cosmos-connection-string"
  value        = azurerm_cosmosdb_account.cosmos.primary_sql_connection_string
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_key_vault_access_policy.user]
}

resource "azurerm_key_vault_secret" "openai_endpoint" {
  name         = "openai-endpoint"
  value        = var.openai_endpoint
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_key_vault_access_policy.user]
}

resource "azurerm_key_vault_secret" "openai_api_key" {
  name         = "openai-api-key"
  value        = var.openai_api_key
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_key_vault_access_policy.user]
}

resource "azurerm_cosmosdb_account" "cosmos" {
  name                = "${var.prefix}-cosmos"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.rg.location
    failover_priority = 0
  }

  tags = local.tags
}

resource "azurerm_cosmosdb_sql_database" "db" {
  name                = "pipeline-db"
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmos.name
}

resource "azurerm_cosmosdb_sql_container" "container" {
  name                = "processed-documents"
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmos.name
  database_name       = azurerm_cosmosdb_sql_database.db.name
  partition_key_paths = ["/partitionKey"] # v4: replaced the singular partition_key_path

  # Match the chatbot project: expire analysis results after 90 days rather
  # than accumulating storage forever.
  default_ttl = 7776000
}

# ─────────────────────────────────────────────────────────
# TODO: provision the Azure OpenAI resource here
#
# azurerm_cognitive_account + azurerm_cognitive_deployment would let this
# config stand alone. Today the OpenAI resource is created outside Terraform
# and passed in via var.openai_endpoint / var.openai_api_key, which is why
# the README no longer claims this provisions everything from scratch.
# ─────────────────────────────────────────────────────────

output "function_app_name" {
  value = azurerm_linux_function_app.func.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.kv.vault_uri
}

output "cosmos_endpoint" {
  value = azurerm_cosmosdb_account.cosmos.endpoint
}
