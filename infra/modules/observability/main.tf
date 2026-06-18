variable "name_suffix" {
  type        = string
  description = "Naming suffix (workload-env-region) used in Log Analytics, App Insights, and budget names."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group where Log Analytics and Application Insights are created."
}

variable "resource_group_id" {
  type        = string
  description = "Resource ID of the resource group used as the scope for the Cost Management budget."
}

variable "location" {
  type        = string
  description = "Azure region for Log Analytics and Application Insights."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all taggable resources in this module."
}

variable "budget_amount" {
  type        = number
  description = "Monthly budget amount in the subscription currency. Triggers notifications at 80 % (Actual) and 100 % (Forecasted)."
}

variable "budget_alert_email" {
  type        = string
  description = "Email address that receives Cost Management budget threshold notifications."
}

variable "budget_start_date" {
  type        = string
  default     = "2026-06-01T00:00:00Z"
  description = "Budget start date; must be the first of a month, UTC, and not in the past when the budget is first created. Override per environment if applying after this month."
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "log-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "appi" {
  name                = "appi-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
  tags                = var.tags
}

# NOTE: "Custom metrics with dimensions" is an Azure Monitor preview opt-in with no reliable
# ARM/Terraform property. The Microsoft.Insights/components REST API (2015-05-01) exposes no
# such field; the feature is toggled exclusively through the portal UI.
# Ref: https://learn.microsoft.com/en-us/azure/azure-monitor/app/metrics-overview#custom-metrics-dimensions-and-pre-aggregation
#
# If the llm-emit-token-metric policy's custom dimensions (team, deployment) appear
# dropped or flattened in the Azure Monitor metrics store, enable this feature once per
# App Insights instance via the portal:
#   App Insights resource -> Usage and estimated costs ->
#   Custom metrics (Preview) -> "With dimensions" -> OK
#
# Metrics still emit without this toggle; only the preaggregated time-series stored in the
# Azure Monitor metrics store will be missing the extra dimensions. The raw events
# (customMetrics table in Log Analytics) always retain all dimensions regardless.
# Note: enabling this incurs additional custom-metrics billing charges.
# This manual step must be documented in the project README (covered in a later task).

resource "azurerm_consumption_budget_resource_group" "budget" {
  name              = "budget-${var.name_suffix}"
  resource_group_id = var.resource_group_id

  amount     = var.budget_amount
  time_grain = "Monthly"

  time_period {
    # Must be first-of-month UTC and not in the past at creation time.
    # Override budget_start_date when applying in a later month (Azure rejects past dates on new budgets).
    start_date = var.budget_start_date
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Actual"
    contact_emails = [var.budget_alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Forecasted"
    contact_emails = [var.budget_alert_email]
  }
}

output "law_id" {
  description = "Resource ID of the Log Analytics workspace (used as workspace_id for workspace-based App Insights and as the APIM diagnostic sink in Phase 2)."
  value       = azurerm_log_analytics_workspace.law.id
}

output "law_customer_id" {
  description = "Log Analytics workspace customerId (GUID) — the workspace id azure-monitor-query LogsQueryClient.query_workspace() takes (distinct from law_id, which is the ARM resource id used for RBAC scope)."
  value       = azurerm_log_analytics_workspace.law.workspace_id
}

output "appi_id" {
  description = "Resource ID of the Application Insights component."
  value       = azurerm_application_insights.appi.id
}

output "appi_connection_string" {
  description = "Application Insights connection string. Marked sensitive — use via Key Vault reference or managed-identity SDK, never logged."
  value       = azurerm_application_insights.appi.connection_string
  sensitive   = true
}

output "appi_instrumentation_key" {
  description = "Application Insights instrumentation key (legacy; prefer connection_string for new SDKs). Marked sensitive."
  value       = azurerm_application_insights.appi.instrumentation_key
  sensitive   = true
}
