terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

provider "azurerm" {
  features {}
}

# ---------------------------------------------------------------------------
# Ownership split:
#   - AKS cluster, AKS tenant namespace, and the tenant's workload identity
#     (user-assigned managed identity + federated identity credential for the
#     workload's ServiceAccount) are provisioned by tenant onboarding and are
#     consumed here only as inputs.
#   - The shared Premium Service Bus namespace (e.g. sb-daas) is provisioned
#     by the landing zone, with local (SAS) auth disabled and private
#     networking. It is referenced by ID only.
#   - This module creates one tenant entity (queue, or topic + subscriptions)
#     and the data-plane role assignments at the exact entity scope. Run it
#     once per entity.
#   - The KEDA trust on the tenant identity is created once per tenant by
#     terraform/tenant-keda-identity, not here: a per-entity module would
#     try to create the same credential again for the tenant's next entity.
#     KEDA polls as the tenant identity, so that identity must be one of the
#     receiver grants below.
# ---------------------------------------------------------------------------

locals {
  is_queue    = var.entity_type == "queue"
  tenant_slug = lower(var.tenant_id)
  entity_name = "${local.is_queue ? "q" : "t"}-${local.tenant_slug}-${var.purpose}"
  lock        = "PT${var.lock_duration_seconds}S"

  namespace_name = element(split("/", var.servicebus_namespace_id), 8)

  # Expand each grant into one role assignment per role it needs.
  role_assignments = merge([
    for key, g in var.access_grants : merge(
      contains(["sender", "sender_receiver"], g.access_mode) ? {
        "${key}-sender" = { principal_id = g.principal_id, role = "Azure Service Bus Data Sender", subscription = null }
      } : {},
      contains(["receiver", "sender_receiver"], g.access_mode) ? {
        "${key}-receiver" = { principal_id = g.principal_id, role = "Azure Service Bus Data Receiver", subscription = g.subscription }
      } : {},
    )
  ]...)

  entity_id = local.is_queue ? azurerm_servicebus_queue.this[0].id : azurerm_servicebus_topic.this[0].id
}

resource "terraform_data" "guardrails" {
  input = local.entity_name

  lifecycle {
    precondition {
      condition     = contains([for id in var.approved_servicebus_namespace_ids : lower(id)], lower(var.servicebus_namespace_id))
      error_message = "servicebus_namespace_id is not in the platform's approved namespace list."
    }
    precondition {
      condition     = local.is_queue ? length(var.subscriptions) == 0 : length(var.subscriptions) > 0
      error_message = "Queues must not declare subscriptions; topics must declare at least one."
    }
    precondition {
      condition = alltrue([
        for g in values(var.access_grants) :
        (local.is_queue || g.access_mode == "sender") ? g.subscription == null : contains(var.subscriptions, coalesce(g.subscription, "-"))
      ])
      error_message = "A topic receiver grant must name one of var.subscriptions; queue grants and topic sender grants must not set subscription."
    }
  }
}

# ---------------------------------------------------------------------------
# Entity
# ---------------------------------------------------------------------------

resource "azurerm_servicebus_queue" "this" {
  count        = local.is_queue ? 1 : 0
  name         = local.entity_name
  namespace_id = var.servicebus_namespace_id

  max_size_in_megabytes                   = var.max_size_in_megabytes
  default_message_ttl                     = var.default_message_ttl
  lock_duration                           = local.lock
  max_delivery_count                      = var.max_delivery_count
  requires_session                        = var.requires_session
  requires_duplicate_detection            = var.requires_duplicate_detection
  duplicate_detection_history_time_window = var.requires_duplicate_detection ? var.duplicate_detection_window : null
  dead_lettering_on_message_expiration    = true

  depends_on = [terraform_data.guardrails]
}

resource "azurerm_servicebus_topic" "this" {
  count        = local.is_queue ? 0 : 1
  name         = local.entity_name
  namespace_id = var.servicebus_namespace_id

  max_size_in_megabytes                   = var.max_size_in_megabytes
  default_message_ttl                     = var.default_message_ttl
  requires_duplicate_detection            = var.requires_duplicate_detection
  duplicate_detection_history_time_window = var.requires_duplicate_detection ? var.duplicate_detection_window : null

  depends_on = [terraform_data.guardrails]
}

resource "azurerm_servicebus_subscription" "this" {
  for_each = local.is_queue ? toset([]) : var.subscriptions
  name     = "sub-${each.value}"
  topic_id = azurerm_servicebus_topic.this[0].id

  lock_duration                        = local.lock
  max_delivery_count                   = var.max_delivery_count
  requires_session                     = var.requires_session
  dead_lettering_on_message_expiration = true
}

# ---------------------------------------------------------------------------
# Data-plane RBAC at the exact entity scope (see variables.tf access_grants).
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "this" {
  for_each = local.role_assignments

  scope = (
    each.value.subscription != null
    ? azurerm_servicebus_subscription.this[each.value.subscription].id
    : local.entity_id
  )
  role_definition_name             = each.value.role
  principal_id                     = each.value.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
