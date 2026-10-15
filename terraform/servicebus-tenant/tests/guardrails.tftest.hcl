# Offline guardrail tests: `terraform init && terraform test`.
# Uses a mocked azurerm provider, so no Azure credentials are needed.

mock_provider "azurerm" {}

variables {
  tenant_id                         = "APP-1234-UC01"
  purpose                           = "orders"
  servicebus_namespace_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lz/providers/Microsoft.ServiceBus/namespaces/sb-example-shared"
  approved_servicebus_namespace_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lz/providers/Microsoft.ServiceBus/namespaces/sb-example-shared"]
  access_grants = {
    worker = { principal_id = "11111111-1111-1111-1111-111111111111", access_mode = "receiver" }
  }
}

run "queue_receiver_scoped_to_queue" {
  command = plan

  assert {
    condition     = output.entity_name == "q-app-1234-uc01-orders"
    error_message = "queue name must follow q-<tenant>-<purpose>"
  }
  assert {
    condition     = output.keda_trigger_metadata.namespace == "sb-example-shared"
    error_message = "KEDA namespace must be the short name"
  }
  assert {
    condition     = keys(azurerm_role_assignment.this) == ["worker-receiver"] && azurerm_role_assignment.this["worker-receiver"].role_definition_name == "Azure Service Bus Data Receiver"
    error_message = "receiver grant must produce exactly one Data Receiver assignment"
  }
  assert {
    condition     = azurerm_servicebus_queue.this[0].lock_duration == "PT60S"
    error_message = "lock duration must be rendered from lock_duration_seconds"
  }
}

run "sender_receiver_gets_two_separate_roles" {
  command = plan
  variables {
    access_grants = {
      app = { principal_id = "11111111-1111-1111-1111-111111111111", access_mode = "sender_receiver" }
    }
  }
  assert {
    condition     = length(azurerm_role_assignment.this) == 2
    error_message = "sender_receiver must produce two role assignments"
  }
}

run "topic_receiver_scoped_to_subscription" {
  command = plan
  variables {
    entity_type   = "topic"
    purpose       = "events"
    subscriptions = ["orders-worker"]
    access_grants = {
      producer = { principal_id = "22222222-2222-2222-2222-222222222222", access_mode = "sender" }
      worker   = { principal_id = "11111111-1111-1111-1111-111111111111", access_mode = "receiver", subscription = "orders-worker" }
    }
  }
  assert {
    condition     = output.entity_name == "t-app-1234-uc01-events" && azurerm_servicebus_subscription.this["orders-worker"].name == "sub-orders-worker"
    error_message = "topic/subscription names must follow the convention"
  }
}

run "rejects_unapproved_namespace" {
  command = plan
  variables {
    servicebus_namespace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-x/providers/Microsoft.ServiceBus/namespaces/sb-rogue"
  }
  expect_failures = [terraform_data.guardrails]
}

run "rejects_free_text_tenant" {
  command = plan
  variables {
    tenant_id = "acme"
  }
  expect_failures = [var.tenant_id]
}

run "rejects_non_canonical_tenant_id" {
  command = plan
  variables {
    tenant_id = "app-1234-uc01"
  }
  expect_failures = [var.tenant_id]
}

run "rejects_malformed_use_case" {
  command = plan
  variables {
    tenant_id = "APP-1234-UC1"
  }
  expect_failures = [var.tenant_id]
}

run "rejects_unapproved_size" {
  command = plan
  variables {
    max_size_in_megabytes = 10240
  }
  expect_failures = [var.max_size_in_megabytes]
}

run "rejects_topic_receiver_without_subscription" {
  command = plan
  variables {
    entity_type   = "topic"
    subscriptions = ["orders-worker"]
  }
  expect_failures = [terraform_data.guardrails]
}

run "rejects_queue_with_subscriptions" {
  command = plan
  variables {
    subscriptions = ["orders-worker"]
  }
  expect_failures = [terraform_data.guardrails]
}
