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
# Default KEDA authentication model ("Option B"): KEDA polls each tenant's
# entities AS THAT TENANT'S identity, never as a shared identity.
#
# KEDA's azure-workload provider always authenticates as the keda-operator
# ServiceAccount. A tenant TriggerAuthentication sets
# podIdentity.identityId = <tenant UAMI client ID>, and KEDA can only get a
# token for that identity if the identity trusts the keda-operator
# ServiceAccount. This module adds that trust: one federated identity
# credential on the tenant's UAMI.
#
# Run it ONCE PER TENANT IDENTITY (per AKS cluster), not per queue/topic: an
# identity can hold only one credential per issuer+subject, so creating it
# from the per-entity module would fail on the tenant's second entity.
#
# The UAMI itself and its credential for the workload ServiceAccount are
# created by tenant onboarding. Isolation between tenants on this path
# depends on platform/admission/keda-tenant-guardrails.yaml, which only lets
# a namespace's TriggerAuthentication name that namespace's own identity.
# ---------------------------------------------------------------------------

locals {
  id_parts = split("/", var.workload_identity_resource_id)
}

data "azurerm_user_assigned_identity" "tenant" {
  name                = element(local.id_parts, 8)
  resource_group_name = element(local.id_parts, 4)
}

resource "azurerm_federated_identity_credential" "keda_operator" {
  name                = var.credential_name
  resource_group_name = data.azurerm_user_assigned_identity.tenant.resource_group_name
  parent_id           = data.azurerm_user_assigned_identity.tenant.id
  issuer              = var.aks_oidc_issuer_url
  subject             = "system:serviceaccount:${var.keda_namespace}:${var.keda_service_account}"
  audience            = ["api://AzureADTokenExchange"]
}
