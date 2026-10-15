output "tenant_id" {
  description = "Canonical tenant ID this entity belongs to. Store it in the registry and on the Kubernetes Namespace label."
  value       = var.tenant_id
}

output "entity_id" {
  description = "ARM resource ID of the tenant's queue or topic."
  value       = local.entity_id
}

output "entity_name" {
  description = "Queue or topic name (q-<tenantid>-<purpose> / t-<tenantid>-<purpose>, lowercase)."
  value       = local.entity_name
}

output "subscription_ids" {
  description = "Topic subscription ARM IDs keyed by consumer slug (empty for queues)."
  value       = { for k, s in azurerm_servicebus_subscription.this : k => s.id }
}

output "rbac_scopes" {
  description = "Exact scope of every data-plane role assignment, keyed by grant. Persist these in the registry (rbac_scope) for reconciliation."
  value       = { for k, ra in azurerm_role_assignment.this : k => { scope = ra.scope, role = ra.role_definition_name, principal_id = ra.principal_id } }
}

output "keda_trigger_metadata" {
  description = "Values for the Helm chart's serviceBus block. KEDA's namespace field is the short namespace name, not the FQDN."
  value = {
    namespace         = local.namespace_name
    entityType        = var.entity_type
    queueName         = local.is_queue ? local.entity_name : null
    topicName         = local.is_queue ? null : local.entity_name
    subscriptionNames = [for s in sort(tolist(var.subscriptions)) : "sub-${s}"]
  }
}
