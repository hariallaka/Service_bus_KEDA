variable "tenant_id" {
  description = "Platform tenant ID, canonical APP-<number>-UC<nn> (e.g. APP-1234-UC01). Recorded in outputs so onboarding can label the Namespace consistently."
  type        = string

  validation {
    condition     = can(regex("^APP-[0-9]{1,8}-UC[0-9]{2}$", var.tenant_id))
    error_message = "tenant_id must match ^APP-[0-9]{1,8}-UC[0-9]{2}$ (canonical uppercase, e.g. APP-1234-UC01)."
  }
}

variable "workload_identity_resource_id" {
  description = "ARM resource ID of the tenant's existing user-assigned managed identity (created by onboarding). The same identity is federated to the tenant's workload ServiceAccount and holds the entity-scoped Service Bus roles."
  type        = string

  validation {
    condition     = can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.ManagedIdentity/userAssignedIdentities/[^/]+$", var.workload_identity_resource_id))
    error_message = "workload_identity_resource_id must be a user-assigned managed identity ARM resource ID."
  }
}

variable "aks_oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster running KEDA (az aks show --query oidcIssuerProfile.issuerUrl)."
  type        = string

  validation {
    condition     = startswith(var.aks_oidc_issuer_url, "https://")
    error_message = "aks_oidc_issuer_url must be an https:// URL."
  }
}

variable "keda_namespace" {
  description = "Namespace the self-managed KEDA operator runs in."
  type        = string
  default     = "keda"
}

variable "keda_service_account" {
  description = "ServiceAccount of the KEDA operator."
  type        = string
  default     = "keda-operator"
}

variable "credential_name" {
  description = "Name of the federated credential on the tenant identity. Must be unique on that identity; use a per-cluster name (e.g. keda-operator-aks-blue) if several clusters run KEDA against the same identities."
  type        = string
  default     = "keda-operator"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{2,119}$", var.credential_name))
    error_message = "credential_name must be 3-120 characters: letters, digits, '-' or '_', starting with a letter or digit."
  }
}
