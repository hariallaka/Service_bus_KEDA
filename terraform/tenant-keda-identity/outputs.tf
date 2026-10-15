output "tenant_id" {
  description = "Canonical tenant ID (Namespace label platform.io/tenant)."
  value       = var.tenant_id
}

output "client_id" {
  description = "Tenant identity client ID. Use it as the Helm chart's identity.clientId and as the Namespace annotation platform.io/workload-identity-client-id."
  value       = data.azurerm_user_assigned_identity.tenant.client_id
}

output "principal_id" {
  description = "Tenant identity principal (object) ID. Use it in terraform/servicebus-tenant access_grants for this tenant's receiving workloads."
  value       = data.azurerm_user_assigned_identity.tenant.principal_id
}

output "keda_federated_subject" {
  description = "Subject trusted by the tenant identity for KEDA."
  value       = azurerm_federated_identity_credential.keda_operator.subject
}

output "namespace_metadata" {
  description = "Labels and annotations tenant onboarding must set on the tenant's Kubernetes Namespace (read by the admission policy)."
  value = {
    labels      = { "platform.io/tenant" = var.tenant_id }
    annotations = { "platform.io/workload-identity-client-id" = data.azurerm_user_assigned_identity.tenant.client_id }
  }
}
