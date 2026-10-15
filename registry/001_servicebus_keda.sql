-- Service Bus + KEDA extension to the PostgreSQL service registry.
--
-- Reference migration for the design's "PostgreSQL update requirements".
-- It only ADDS Service Bus/KEDA tables; the existing service ownership model
-- is referenced through service_id (wire the FK to your existing table where
-- marked). Rules from the design are enforced as constraints and triggers,
-- not only inside the upsert procedures, so no other write path (ad-hoc SQL,
-- a new procedure, a migration) can store an invalid record.
--
-- Differences from the design table, and why:
--   * Access is a separate table (sb_access_grant). The design puts
--     access_mode on the entity, which can't represent a producer workload
--     and a consumer workload on the same queue, and would make "one owner
--     per entity" conflict with legitimate multi-workload access.
--   * entity_name and subscription_name are GENERATED from tenant_id/
--     purpose/consumer, so the naming convention can't drift. tenant_id is
--     stored in canonical form (APP-1234-UC01); names use its lowercase form
--     (q-app-1234-uc01-orders) because Service Bus names are case-insensitive
--     while text uniqueness here is case-sensitive.
--   * rbac_scopes is computed by trigger from the approved namespace's
--     resource ID and is never accepted from the caller. It is an array
--     because a topic sender_receiver grant needs two scopes (send on the
--     topic, receive on the subscription).
--   * Workload identity and Kubernetes binding (principal/client ID,
--     namespace, ServiceAccount) are stored, because reconciliation and the
--     KEDA TriggerAuthentication identityId need them.

BEGIN;

CREATE SCHEMA IF NOT EXISTS service_registry;
SET LOCAL search_path = service_registry;

CREATE TYPE provisioning_status AS ENUM ('requested', 'provisioned', 'failed', 'suspended', 'retired');
CREATE TYPE sb_entity_type      AS ENUM ('queue', 'topic');
CREATE TYPE sb_access_mode      AS ENUM ('sender', 'receiver', 'sender_receiver');

-- ---------------------------------------------------------------------------
-- Platform-owned reference data
-- ---------------------------------------------------------------------------

CREATE TABLE sb_platform_limits (
    environment                  text PRIMARY KEY,
    max_replica_cap              int  NOT NULL CHECK (max_replica_cap > 0),
    max_message_count            int  NOT NULL CHECK (max_message_count > 0),
    min_polling_interval_seconds int  NOT NULL CHECK (min_polling_interval_seconds > 0),
    allowed_max_size_mb          int[] NOT NULL DEFAULT '{1024,2048,3072,4096,5120}'
);

CREATE TABLE sb_approved_namespace (
    namespace_name      text PRIMARY KEY CHECK (namespace_name ~ '^[a-zA-Z][a-zA-Z0-9-]{4,48}[a-zA-Z0-9]$'),
    environment         text NOT NULL REFERENCES sb_platform_limits (environment),
    resource_id         text NOT NULL UNIQUE
                        CHECK (resource_id ~* '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ServiceBus/namespaces/[^/]+$'),
    sku                 text NOT NULL CHECK (sku = 'Premium'),
    -- Hardening rule: only namespaces with SAS/local auth disabled may be approved.
    local_auth_disabled boolean NOT NULL CHECK (local_auth_disabled),
    is_active           boolean NOT NULL DEFAULT true,
    UNIQUE (namespace_name, environment)
);

-- ---------------------------------------------------------------------------
-- Service Bus entities
-- ---------------------------------------------------------------------------

CREATE TABLE sb_entity (
    id                           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    service_id                   bigint NOT NULL,  -- FK to the existing service table, e.g. REFERENCES service_registry.service (id)
    -- Canonical tenant ID: application + use case. Wire the FK to your
    -- existing tenant table, e.g. REFERENCES service_registry.tenant (tenant_id),
    -- so only onboarded tenants can own entities.
    tenant_id                    text NOT NULL CHECK (tenant_id ~ '^APP-[0-9]{1,8}-UC[0-9]{2}$'),
    purpose                      text NOT NULL CHECK (purpose ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(purpose) <= 40),
    environment                  text NOT NULL,
    service_bus_namespace        text NOT NULL,
    entity_type                  sb_entity_type NOT NULL,
    entity_name                  text GENERATED ALWAYS AS (
                                     CASE entity_type WHEN 'queue' THEN 'q-' ELSE 't-' END || lower(tenant_id) || '-' || purpose
                                 ) STORED,
    max_size_mb                  int NOT NULL,
    -- Queue lock duration; for topics it applies to each subscription.
    lock_duration_seconds        int NOT NULL CHECK (lock_duration_seconds BETWEEN 5 AND 300),
    max_delivery_count           int NOT NULL DEFAULT 10 CHECK (max_delivery_count BETWEEN 1 AND 100),
    requires_session             boolean NOT NULL DEFAULT false,
    requires_duplicate_detection boolean NOT NULL DEFAULT false,
    provisioning_status          provisioning_status NOT NULL DEFAULT 'requested',
    created_at                   timestamptz NOT NULL DEFAULT now(),
    updated_at                   timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (service_bus_namespace, environment) REFERENCES sb_approved_namespace (namespace_name, environment),
    UNIQUE (id, entity_type)
);

-- An active entity has exactly one owner per namespace (entity names are
-- namespace-global in Service Bus). Retired rows keep their history.
CREATE UNIQUE INDEX sb_entity_active_name_uq
    ON sb_entity (service_bus_namespace, entity_name)
    WHERE provisioning_status <> 'retired';

CREATE TABLE sb_subscription (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entity_id           bigint NOT NULL,
    entity_type         sb_entity_type NOT NULL DEFAULT 'topic' CHECK (entity_type = 'topic'),
    consumer            text NOT NULL CHECK (consumer ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(consumer) <= 46),
    subscription_name   text GENERATED ALWAYS AS ('sub-' || consumer) STORED,
    provisioning_status provisioning_status NOT NULL DEFAULT 'requested',
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    -- A queue must not have a subscription: the parent must be a topic.
    FOREIGN KEY (entity_id, entity_type) REFERENCES sb_entity (id, entity_type),
    UNIQUE (id, entity_id)
);

CREATE UNIQUE INDEX sb_subscription_active_name_uq
    ON sb_subscription (entity_id, subscription_name)
    WHERE provisioning_status <> 'retired';

-- ---------------------------------------------------------------------------
-- Data-plane access (one row per workload identity per entity)
-- ---------------------------------------------------------------------------

CREATE TABLE sb_access_grant (
    id                             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entity_id                      bigint NOT NULL REFERENCES sb_entity (id),
    subscription_id                bigint,
    access_mode                    sb_access_mode NOT NULL,
    workload_identity_principal_id uuid NOT NULL,
    workload_identity_client_id    uuid NOT NULL,
    k8s_namespace                  text NOT NULL CHECK (k8s_namespace ~ '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' AND length(k8s_namespace) <= 63),
    service_account                text NOT NULL,
    -- Computed by trigger; any caller-supplied value is overwritten.
    rbac_scopes                    text[] NOT NULL DEFAULT '{}',
    provisioning_status            provisioning_status NOT NULL DEFAULT 'requested',
    created_at                     timestamptz NOT NULL DEFAULT now(),
    updated_at                     timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (subscription_id, entity_id) REFERENCES sb_subscription (id, entity_id)
);

CREATE UNIQUE INDEX sb_access_grant_active_uq
    ON sb_access_grant (entity_id, COALESCE(subscription_id, 0), workload_identity_principal_id)
    WHERE provisioning_status <> 'retired';

-- ---------------------------------------------------------------------------
-- KEDA scaling contract (one per receiving grant)
-- ---------------------------------------------------------------------------

CREATE TABLE keda_scaling (
    id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    access_grant_id             bigint NOT NULL UNIQUE REFERENCES sb_access_grant (id),
    scaler_type                 text NOT NULL DEFAULT 'azure-servicebus' CHECK (scaler_type = 'azure-servicebus'),
    message_count               int NOT NULL DEFAULT 10 CHECK (message_count > 0),
    activation_message_count    int NOT NULL DEFAULT 0 CHECK (activation_message_count >= 0),
    min_replica_count           int NOT NULL DEFAULT 1 CHECK (min_replica_count >= 0),
    max_replica_count           int NOT NULL DEFAULT 10 CHECK (max_replica_count >= 1),
    polling_interval_seconds    int NOT NULL DEFAULT 30 CHECK (polling_interval_seconds > 0),
    cooldown_period_seconds     int NOT NULL DEFAULT 300 CHECK (cooldown_period_seconds >= 0),
    scaled_object_name          text NOT NULL CHECK (scaled_object_name ~ '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' AND length(scaled_object_name) <= 63),
    trigger_authentication_name text NOT NULL CHECK (trigger_authentication_name ~ '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' AND length(trigger_authentication_name) <= 63),
    scaling_enabled             boolean NOT NULL DEFAULT true,
    provisioning_status         provisioning_status NOT NULL DEFAULT 'requested',
    created_at                  timestamptz NOT NULL DEFAULT now(),
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    CHECK (min_replica_count <= max_replica_count)
);

-- ---------------------------------------------------------------------------
-- Validation triggers (rules that need other rows)
-- ---------------------------------------------------------------------------

CREATE FUNCTION sb_entity_validate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    lim sb_platform_limits;
BEGIN
    SELECT l.* INTO lim FROM sb_platform_limits l WHERE l.environment = NEW.environment;
    IF NOT NEW.max_size_mb = ANY (lim.allowed_max_size_mb) THEN
        RAISE EXCEPTION 'max_size_mb % is not an approved size %', NEW.max_size_mb, lim.allowed_max_size_mb
            USING ERRCODE = 'check_violation';
    END IF;
    IF (TG_OP = 'INSERT' OR NEW.service_bus_namespace IS DISTINCT FROM OLD.service_bus_namespace)
       AND NOT (SELECT is_active FROM sb_approved_namespace WHERE namespace_name = NEW.service_bus_namespace) THEN
        RAISE EXCEPTION 'Service Bus namespace % is not active for new entities', NEW.service_bus_namespace
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER sb_entity_validate BEFORE INSERT OR UPDATE ON sb_entity
    FOR EACH ROW EXECUTE FUNCTION sb_entity_validate();

CREATE FUNCTION sb_access_grant_validate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    e   sb_entity;
    ns  text;
    sub text;
    base text;
BEGIN
    SELECT * INTO e FROM sb_entity WHERE id = NEW.entity_id;
    SELECT resource_id INTO ns FROM sb_approved_namespace WHERE namespace_name = e.service_bus_namespace;

    IF e.entity_type = 'queue' AND NEW.subscription_id IS NOT NULL THEN
        RAISE EXCEPTION 'a queue grant must not reference a subscription' USING ERRCODE = 'check_violation';
    END IF;
    IF e.entity_type = 'topic' AND NEW.access_mode <> 'sender' AND NEW.subscription_id IS NULL THEN
        RAISE EXCEPTION 'a topic receiver must have a subscription (receive is never granted at topic scope)'
            USING ERRCODE = 'check_violation';
    END IF;
    IF e.entity_type = 'topic' AND NEW.access_mode = 'sender' AND NEW.subscription_id IS NOT NULL THEN
        RAISE EXCEPTION 'a topic sender is scoped to the topic, not a subscription' USING ERRCODE = 'check_violation';
    END IF;

    base := ns || CASE e.entity_type WHEN 'queue' THEN '/queues/' ELSE '/topics/' END || e.entity_name;
    IF NEW.subscription_id IS NOT NULL THEN
        SELECT subscription_name INTO sub FROM sb_subscription WHERE id = NEW.subscription_id;
    END IF;

    NEW.rbac_scopes := ARRAY[]::text[];
    IF NEW.access_mode IN ('sender', 'sender_receiver') THEN
        NEW.rbac_scopes := NEW.rbac_scopes || base;
    END IF;
    IF NEW.access_mode IN ('receiver', 'sender_receiver') THEN
        NEW.rbac_scopes := NEW.rbac_scopes || CASE WHEN sub IS NULL THEN base ELSE base || '/subscriptions/' || sub END;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER sb_access_grant_validate BEFORE INSERT OR UPDATE ON sb_access_grant
    FOR EACH ROW EXECUTE FUNCTION sb_access_grant_validate();

CREATE FUNCTION keda_scaling_validate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    g   sb_access_grant;
    lim sb_platform_limits;
BEGIN
    SELECT * INTO g FROM sb_access_grant WHERE id = NEW.access_grant_id;
    IF g.access_mode = 'sender' THEN
        RAISE EXCEPTION 'KEDA scaling requires a receiving grant (receiver or sender_receiver)'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT l.* INTO lim
      FROM sb_platform_limits l JOIN sb_entity e ON e.environment = l.environment
     WHERE e.id = g.entity_id;
    IF NEW.max_replica_count > lim.max_replica_cap THEN
        RAISE EXCEPTION 'max_replica_count % exceeds the approved cap %', NEW.max_replica_count, lim.max_replica_cap
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.message_count > lim.max_message_count THEN
        RAISE EXCEPTION 'message_count % exceeds the approved maximum %', NEW.message_count, lim.max_message_count
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.polling_interval_seconds < lim.min_polling_interval_seconds THEN
        RAISE EXCEPTION 'polling_interval_seconds % is below the approved minimum %', NEW.polling_interval_seconds, lim.min_polling_interval_seconds
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1 FROM keda_scaling k JOIN sb_access_grant o ON o.id = k.access_grant_id
         WHERE o.k8s_namespace = g.k8s_namespace AND k.scaled_object_name = NEW.scaled_object_name
           AND k.id IS DISTINCT FROM NEW.id AND k.provisioning_status <> 'retired'
    ) THEN
        RAISE EXCEPTION 'ScaledObject % already exists in namespace %', NEW.scaled_object_name, g.k8s_namespace
            USING ERRCODE = 'unique_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER keda_scaling_validate BEFORE INSERT OR UPDATE ON keda_scaling
    FOR EACH ROW EXECUTE FUNCTION keda_scaling_validate();

-- ---------------------------------------------------------------------------
-- Provisioning status state machine + "mark for reconciliation on change"
-- ---------------------------------------------------------------------------

CREATE FUNCTION registry_status_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    spec_changed boolean;
BEGIN
    IF OLD.provisioning_status = 'retired' THEN
        RAISE EXCEPTION '% row % is retired and immutable', TG_TABLE_NAME, OLD.id USING ERRCODE = 'check_violation';
    END IF;

    -- Generated columns are excluded: they are not yet computed in a BEFORE
    -- trigger (NULL in NEW) and follow from the columns that are compared.
    spec_changed := (to_jsonb(NEW) - ARRAY['provisioning_status', 'updated_at', 'rbac_scopes', 'entity_name', 'subscription_name'])
                 IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['provisioning_status', 'updated_at', 'rbac_scopes', 'entity_name', 'subscription_name']);

    IF spec_changed THEN
        IF NEW.provisioning_status IS DISTINCT FROM OLD.provisioning_status THEN
            RAISE EXCEPTION 'change spec and provisioning_status in separate updates' USING ERRCODE = 'check_violation';
        END IF;
        -- Any change to entity/KEDA details is re-queued for reconciliation.
        NEW.provisioning_status := 'requested';
    ELSIF NEW.provisioning_status IS DISTINCT FROM OLD.provisioning_status AND NOT (
        (OLD.provisioning_status, NEW.provisioning_status) IN (
            ('requested',   'provisioned'), ('requested',   'failed'), ('requested', 'retired'),
            ('provisioned', 'requested'),   ('provisioned', 'suspended'), ('provisioned', 'failed'), ('provisioned', 'retired'),
            ('failed',      'requested'),   ('failed',      'retired'),
            ('suspended',   'requested'),   ('suspended',   'provisioned'), ('suspended', 'retired')
        )
    ) THEN
        RAISE EXCEPTION 'invalid provisioning_status transition % -> % on %', OLD.provisioning_status, NEW.provisioning_status, TG_TABLE_NAME
            USING ERRCODE = 'check_violation';
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END $$;

-- Retiring an entity retires everything that depends on it, so
-- reconciliation removes KEDA objects and role assignments before the entity
-- (a role assignment left on a deleted scope is orphaned, not revoked).
CREATE FUNCTION sb_entity_cascade_retire() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.provisioning_status = 'retired' AND OLD.provisioning_status <> 'retired' THEN
        UPDATE keda_scaling SET provisioning_status = 'retired'
         WHERE provisioning_status <> 'retired'
           AND access_grant_id IN (SELECT id FROM sb_access_grant WHERE entity_id = NEW.id);
        UPDATE sb_access_grant SET provisioning_status = 'retired'
         WHERE entity_id = NEW.id AND provisioning_status <> 'retired';
        UPDATE sb_subscription SET provisioning_status = 'retired'
         WHERE entity_id = NEW.id AND provisioning_status <> 'retired';
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER sb_entity_cascade_retire AFTER UPDATE OF provisioning_status ON sb_entity
    FOR EACH ROW EXECUTE FUNCTION sb_entity_cascade_retire();

-- ---------------------------------------------------------------------------
-- Audit: old and new values, changed by, timestamp
-- ---------------------------------------------------------------------------

CREATE TABLE registry_audit (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name text NOT NULL,
    record_id  bigint NOT NULL,
    operation  text NOT NULL,
    old_row    jsonb,
    new_row    jsonb,
    -- Procedures should SET LOCAL registry.actor = '<requesting user>' so the
    -- audit records the human/pipeline, not the shared DB login.
    changed_by text NOT NULL,
    changed_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION registry_audit_row() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO registry_audit (table_name, record_id, operation, old_row, new_row, changed_by)
    VALUES (
        TG_TABLE_NAME,
        COALESCE(NEW.id, OLD.id),
        TG_OP,
        CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END,
        COALESCE(NULLIF(current_setting('registry.actor', true), ''), session_user)
    );
    RETURN NULL;
END $$;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['sb_entity', 'sb_subscription', 'sb_access_grant', 'keda_scaling'] LOOP
        EXECUTE format('CREATE TRIGGER %1$s_status_guard BEFORE UPDATE ON %1$I FOR EACH ROW EXECUTE FUNCTION registry_status_guard()', t);
        EXECUTE format('CREATE TRIGGER %1$s_audit AFTER INSERT OR UPDATE OR DELETE ON %1$I FOR EACH ROW EXECUTE FUNCTION registry_audit_row()', t);
    END LOOP;
END $$;

-- Records are retired, never deleted, so the audit trail stays complete.
REVOKE DELETE ON sb_entity, sb_subscription, sb_access_grant, keda_scaling FROM PUBLIC;

COMMIT;
