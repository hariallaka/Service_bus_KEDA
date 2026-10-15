-- Tests for ../001_servicebus_keda.sql. Run against a scratch database:
--   psql -v ON_ERROR_STOP=1 -f ../001_servicebus_keda.sql -f 001_servicebus_keda_test.sql
-- Each negative case must raise; the script fails on the first rule that
-- doesn't hold.

SET search_path = service_registry;
SET registry.actor = 'test-pipeline';

CREATE FUNCTION pg_temp.expect_error(sql text, fragment text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE sql;
    RAISE EXCEPTION 'expected failure containing "%" but statement succeeded: %', fragment, sql;
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'expected failure%' THEN RAISE; END IF;
    IF position(fragment IN SQLERRM) = 0 THEN
        RAISE EXCEPTION 'expected error containing "%", got "%" for: %', fragment, SQLERRM, sql;
    END IF;
END $$;

INSERT INTO sb_platform_limits VALUES ('prod', 50, 1000, 15, DEFAULT);
INSERT INTO sb_approved_namespace VALUES
  ('sb-example-shared', 'prod', '/subscriptions/0000/resourceGroups/rg-lz/providers/Microsoft.ServiceBus/namespaces/sb-example-shared', 'Premium', true, true);

-- Namespace hardening
SELECT pg_temp.expect_error($$INSERT INTO sb_approved_namespace VALUES ('sb-std1', 'prod', '/subscriptions/0/resourceGroups/r/providers/Microsoft.ServiceBus/namespaces/sb-std1', 'Standard', true, true)$$, 'sb_approved_namespace_sku_check');
SELECT pg_temp.expect_error($$INSERT INTO sb_approved_namespace VALUES ('sb-sas1', 'prod', '/subscriptions/0/resourceGroups/r/providers/Microsoft.ServiceBus/namespaces/sb-sas1', 'Premium', false, true)$$, 'local_auth_disabled_check');

-- Valid queue + topic
INSERT INTO sb_entity (service_id, tenant_id, purpose, environment, service_bus_namespace, entity_type, max_size_mb, lock_duration_seconds)
VALUES (1, 'APP-1234-UC01', 'orders', 'prod', 'sb-example-shared', 'queue', 1024, 60),
       (2, 'APP-5678-UC02', 'events', 'prod', 'sb-example-shared', 'topic', 2048, 30);

DO $$ BEGIN
  ASSERT (SELECT entity_name FROM sb_entity WHERE id = 1) = 'q-app-1234-uc01-orders';
  ASSERT (SELECT entity_name FROM sb_entity WHERE id = 2) = 't-app-5678-uc02-events';
END $$;

-- Entity rules
SELECT pg_temp.expect_error($$INSERT INTO sb_entity (service_id, tenant_id, purpose, environment, service_bus_namespace, entity_type, max_size_mb, lock_duration_seconds) VALUES (3, 'APP-1234-UC01', 'orders', 'prod', 'sb-rogue', 'queue', 1024, 60)$$, 'foreign key');
SELECT pg_temp.expect_error($$INSERT INTO sb_entity (service_id, tenant_id, purpose, environment, service_bus_namespace, entity_type, max_size_mb, lock_duration_seconds) VALUES (3, 'acme', 'orders', 'prod', 'sb-example-shared', 'queue', 1024, 60)$$, 'sb_entity_tenant_id_check');
SELECT pg_temp.expect_error($$INSERT INTO sb_entity (service_id, tenant_id, purpose, environment, service_bus_namespace, entity_type, max_size_mb, lock_duration_seconds) VALUES (3, 'app-1234-uc01', 'orders', 'prod', 'sb-example-shared', 'queue', 1024, 60)$$, 'sb_entity_tenant_id_check');
SELECT pg_temp.expect_error($$INSERT INTO sb_entity (service_id, tenant_id, purpose, environment, service_bus_namespace, entity_type, max_size_mb, lock_duration_seconds) VALUES (3, 'APP-1234-UC1', 'orders', 'prod', 'sb-example-shared', 'queue', 1024, 60)$$, 'sb_entity_tenant_id_check');
SELECT pg_temp.expect_error($$INSERT INTO sb_entity (service_id, tenant_id, purpose, environment, service_bus_namespace, entity_type, max_size_mb, lock_duration_seconds) VALUES (9, 'APP-1234-UC01', 'orders', 'prod', 'sb-example-shared', 'queue', 1024, 60)$$, 'sb_entity_active_name_uq');
SELECT pg_temp.expect_error($$INSERT INTO sb_entity (service_id, tenant_id, purpose, environment, service_bus_namespace, entity_type, max_size_mb, lock_duration_seconds) VALUES (3, 'APP-1234-UC01', 'big', 'prod', 'sb-example-shared', 'queue', 10240, 60)$$, 'not an approved size');
SELECT pg_temp.expect_error($$INSERT INTO sb_entity (service_id, tenant_id, purpose, environment, service_bus_namespace, entity_type, max_size_mb, lock_duration_seconds) VALUES (3, 'APP-1234-UC01', 'slow', 'prod', 'sb-example-shared', 'queue', 1024, 600)$$, 'lock_duration_seconds_check');
SELECT pg_temp.expect_error($$INSERT INTO sb_entity (service_id, tenant_id, purpose, environment, service_bus_namespace, entity_type, max_size_mb, lock_duration_seconds, entity_name) VALUES (3, 'APP-1234-UC01', 'x', 'prod', 'sb-example-shared', 'queue', 1024, 60, 'q-app-5678-uc02-x')$$, 'non-DEFAULT value');

-- Subscriptions: only on topics
INSERT INTO sb_subscription (entity_id, consumer) VALUES (2, 'billing-worker');
SELECT pg_temp.expect_error($$INSERT INTO sb_subscription (entity_id, consumer) VALUES (1, 'worker')$$, 'foreign key');

-- Grants and computed RBAC scopes
INSERT INTO sb_access_grant (entity_id, access_mode, workload_identity_principal_id, workload_identity_client_id, k8s_namespace, service_account, rbac_scopes)
VALUES (1, 'receiver', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-00000000000a', 'tenant-app-1234-uc01', 'sb-consumer-sa',
        '{/subscriptions/0000/resourceGroups/rg-lz/providers/Microsoft.ServiceBus/namespaces/sb-example-shared}');  -- tampered scope is overwritten
INSERT INTO sb_access_grant (entity_id, subscription_id, access_mode, workload_identity_principal_id, workload_identity_client_id, k8s_namespace, service_account)
VALUES (2, 1, 'sender_receiver', '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-0000-0000-0000-00000000000b', 'tenant-app-5678-uc02', 'sb-consumer-sa');

DO $$ BEGIN
  ASSERT (SELECT rbac_scopes FROM sb_access_grant WHERE id = 1)
       = ARRAY['/subscriptions/0000/resourceGroups/rg-lz/providers/Microsoft.ServiceBus/namespaces/sb-example-shared/queues/q-app-1234-uc01-orders'],
       'queue receiver must be scoped to the queue, caller-supplied scope ignored';
  ASSERT (SELECT rbac_scopes FROM sb_access_grant WHERE id = 2)
       = ARRAY['/subscriptions/0000/resourceGroups/rg-lz/providers/Microsoft.ServiceBus/namespaces/sb-example-shared/topics/t-app-5678-uc02-events',
               '/subscriptions/0000/resourceGroups/rg-lz/providers/Microsoft.ServiceBus/namespaces/sb-example-shared/topics/t-app-5678-uc02-events/subscriptions/sub-billing-worker'],
       'topic sender_receiver must send at topic scope and receive at subscription scope';
END $$;

SELECT pg_temp.expect_error($$INSERT INTO sb_access_grant (entity_id, access_mode, workload_identity_principal_id, workload_identity_client_id, k8s_namespace, service_account) VALUES (2, 'receiver', '33333333-3333-3333-3333-333333333333', 'cccccccc-0000-0000-0000-00000000000c', 'tenant-app-5678-uc02', 'sa')$$, 'never granted at topic scope');
SELECT pg_temp.expect_error($$INSERT INTO sb_access_grant (entity_id, subscription_id, access_mode, workload_identity_principal_id, workload_identity_client_id, k8s_namespace, service_account) VALUES (1, 1, 'receiver', '33333333-3333-3333-3333-333333333333', 'cccccccc-0000-0000-0000-00000000000c', 'tenant-app-1234-uc01', 'sa')$$, 'must not reference a subscription');

-- KEDA rules
INSERT INTO keda_scaling (access_grant_id, scaled_object_name, trigger_authentication_name) VALUES (1, 'so-orders-worker', 'ta-orders-worker');
DO $$ BEGIN
  ASSERT (SELECT (message_count, activation_message_count, min_replica_count, max_replica_count, polling_interval_seconds, cooldown_period_seconds)
            = (10, 0, 1, 10, 30, 300) FROM keda_scaling WHERE id = 1), 'design defaults';
END $$;
SELECT pg_temp.expect_error($$INSERT INTO keda_scaling (access_grant_id, scaled_object_name, trigger_authentication_name, max_replica_count) VALUES (2, 'so-x', 'ta-x', 500)$$, 'exceeds the approved cap');
SELECT pg_temp.expect_error($$INSERT INTO keda_scaling (access_grant_id, scaled_object_name, trigger_authentication_name, min_replica_count, max_replica_count) VALUES (2, 'so-x', 'ta-x', 5, 2)$$, 'keda_scaling_check');
SELECT pg_temp.expect_error($$INSERT INTO keda_scaling (access_grant_id, scaled_object_name, trigger_authentication_name, message_count) VALUES (2, 'so-x', 'ta-x', 0)$$, 'message_count_check');
SELECT pg_temp.expect_error($$INSERT INTO keda_scaling (access_grant_id, scaled_object_name, trigger_authentication_name, polling_interval_seconds) VALUES (2, 'so-x', 'ta-x', 5)$$, 'below the approved minimum');
SELECT pg_temp.expect_error($$INSERT INTO keda_scaling (access_grant_id, scaled_object_name, trigger_authentication_name, scaler_type) VALUES (2, 'so-x', 'ta-x', 'azure-queue')$$, 'scaler_type_check');

-- Status machine and reconciliation marking
UPDATE keda_scaling SET provisioning_status = 'provisioned' WHERE id = 1;
UPDATE keda_scaling SET max_replica_count = 20 WHERE id = 1;
DO $$ BEGIN
  ASSERT (SELECT provisioning_status FROM keda_scaling WHERE id = 1) = 'requested', 'spec change must re-queue reconciliation';
END $$;
SELECT pg_temp.expect_error($$UPDATE keda_scaling SET provisioning_status = 'suspended' WHERE id = 1$$, 'invalid provisioning_status transition');
SELECT pg_temp.expect_error($$UPDATE keda_scaling SET max_replica_count = 15, provisioning_status = 'provisioned' WHERE id = 1$$, 'separate updates');

-- Retiring an entity retires its dependants; retired rows are immutable
UPDATE sb_entity SET provisioning_status = 'retired' WHERE id = 1;
DO $$ BEGIN
  ASSERT (SELECT provisioning_status FROM sb_access_grant WHERE id = 1) = 'retired';
  ASSERT (SELECT provisioning_status FROM keda_scaling WHERE id = 1) = 'retired';
END $$;
SELECT pg_temp.expect_error($$UPDATE sb_entity SET lock_duration_seconds = 30 WHERE id = 1$$, 'retired and immutable');
-- ...and the name can be reused by a new active owner.
INSERT INTO sb_entity (service_id, tenant_id, purpose, environment, service_bus_namespace, entity_type, max_size_mb, lock_duration_seconds)
VALUES (5, 'APP-1234-UC01', 'orders', 'prod', 'sb-example-shared', 'queue', 1024, 60);

-- Audit captured old/new values and the actor
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM registry_audit WHERE table_name = 'keda_scaling' AND operation = 'UPDATE'
            AND old_row->>'max_replica_count' = '10' AND new_row->>'max_replica_count' = '20' AND changed_by = 'test-pipeline') = 1,
         'audit must record old/new values and actor';
END $$;

SELECT 'ALL REGISTRY TESTS PASSED' AS result;
