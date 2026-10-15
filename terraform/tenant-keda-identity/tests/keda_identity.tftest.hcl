# Offline tests: `terraform init && terraform test`. Mocked azurerm provider.

mock_provider "azurerm" {
  mock_data "azurerm_user_assigned_identity" {
    defaults = {
      id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ids/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-app-1234-uc01"
      resource_group_name = "rg-ids"
      client_id           = "00000000-0000-0000-0000-00000000000a"
      principal_id        = "11111111-1111-1111-1111-111111111111"
    }
  }
}

variables {
  tenant_id                     = "APP-1234-UC01"
  workload_identity_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ids/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-app-1234-uc01"
  aks_oidc_issuer_url           = "https://westeurope.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/11111111-1111-1111-1111-111111111111/"
}

run "default_trusts_keda_namespace_operator" {
  command = plan

  assert {
    condition     = azurerm_federated_identity_credential.keda_operator.subject == "system:serviceaccount:keda:keda-operator"
    error_message = "default subject must be the KEDA operator in the keda namespace"
  }
  assert {
    condition     = azurerm_federated_identity_credential.keda_operator.parent_id == var.workload_identity_resource_id
    error_message = "credential must be on the tenant's own identity"
  }
  assert {
    condition     = one(azurerm_federated_identity_credential.keda_operator.audience) == "api://AzureADTokenExchange"
    error_message = "audience must be the Entra token exchange audience"
  }
  assert {
    condition     = output.namespace_metadata.annotations["platform.io/workload-identity-client-id"] == "00000000-0000-0000-0000-00000000000a" && output.namespace_metadata.labels["platform.io/tenant"] == "APP-1234-UC01"
    error_message = "namespace metadata must carry the tenant ID and the identity's client ID"
  }
}

run "custom_keda_install" {
  command = plan
  variables {
    keda_namespace  = "keda-system"
    credential_name = "keda-operator-aks-blue"
  }
  assert {
    condition     = azurerm_federated_identity_credential.keda_operator.subject == "system:serviceaccount:keda-system:keda-operator"
    error_message = "subject must follow keda_namespace"
  }
}

run "rejects_non_identity_resource" {
  command = plan
  variables {
    workload_identity_resource_id = "/subscriptions/0/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/sb-daas"
  }
  expect_failures = [var.workload_identity_resource_id]
}

run "rejects_bad_tenant_id" {
  command = plan
  variables {
    tenant_id = "app-1234-uc01"
  }
  expect_failures = [var.tenant_id]
}

run "rejects_http_issuer" {
  command = plan
  variables {
    aks_oidc_issuer_url = "http://issuer.example"
  }
  expect_failures = [var.aks_oidc_issuer_url]
}
