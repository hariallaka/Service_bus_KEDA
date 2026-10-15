# ---------------------------------------------------------------------------
# Identity of the entity. The entity name is DERIVED from tenant ID + purpose
# (q-<tenantid>-<purpose> / t-<tenantid>-<purpose>, lowercase) rather than
# passed in, so the naming convention in the design (and the prefix checks in
# platform/admission/keda-tenant-guardrails.yaml) can't be bypassed by a
# caller choosing an arbitrary name. The tenant ID's fixed structure
# (APP-<digits>-UC<2 digits>) means one tenant's prefix can never be a prefix
# of another tenant's names.
# ---------------------------------------------------------------------------

variable "tenant_id" {
  description = "Platform tenant ID in canonical form APP-<number>-UC<nn>, e.g. \"APP-1234-UC01\". One tenant ID is one isolation unit (application + use case): its own identity, Kubernetes namespace and entities. Resource names use the lowercase form (q-app-1234-uc01-<purpose>), because Service Bus names are case-insensitive and Kubernetes names must be lowercase."
  type        = string

  validation {
    condition     = can(regex("^APP-[0-9]{1,8}-UC[0-9]{2}$", var.tenant_id))
    error_message = "tenant_id must match ^APP-[0-9]{1,8}-UC[0-9]{2}$ (canonical uppercase, e.g. APP-1234-UC01)."
  }
}

variable "purpose" {
  description = "Use-case slug, e.g. \"orders\". Becomes the <purpose> part of q-<tenantid>-<purpose> / t-<tenantid>-<purpose>."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.purpose)) && length(var.purpose) <= 40
    error_message = "purpose must be lowercase alphanumerics separated by single hyphens, at most 40 characters."
  }
}

variable "entity_type" {
  description = "\"queue\" for point-to-point processing, \"topic\" for fan-out (consumers then receive from subscriptions)."
  type        = string
  default     = "queue"

  validation {
    condition     = contains(["queue", "topic"], var.entity_type)
    error_message = "entity_type must be \"queue\" or \"topic\"."
  }
}

# ---------------------------------------------------------------------------
# Shared landing-zone namespace (provisioned elsewhere, never created here).
# ---------------------------------------------------------------------------

variable "servicebus_namespace_id" {
  description = "ARM resource ID of the shared Service Bus Premium namespace (e.g. sb-daas). Not created or read by this module: reading it via the azurerm_servicebus_namespace data source would copy the namespace's SAS connection strings into Terraform state."
  type        = string

  validation {
    condition     = can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.ServiceBus/namespaces/[^/]+$", var.servicebus_namespace_id))
    error_message = "servicebus_namespace_id must be a Service Bus namespace ARM resource ID."
  }
}

variable "approved_servicebus_namespace_ids" {
  description = "Platform-owned allowlist of namespace resource IDs tenants may place entities in. Supply it from platform configuration, not from the tenant's request."
  type        = list(string)

  validation {
    condition     = length(var.approved_servicebus_namespace_ids) > 0
    error_message = "approved_servicebus_namespace_ids must not be empty."
  }
}

# ---------------------------------------------------------------------------
# Entity settings (platform-approved values only).
# ---------------------------------------------------------------------------

variable "max_size_in_megabytes" {
  description = "Approved entity capacity: 1, 2, 3, 4 or 5 GB."
  type        = number
  default     = 1024

  validation {
    condition     = contains([1024, 2048, 3072, 4096, 5120], var.max_size_in_megabytes)
    error_message = "max_size_in_megabytes must be one of 1024, 2048, 3072, 4096, 5120."
  }
}

variable "lock_duration_seconds" {
  description = "Message lock duration for consumers, in seconds. Set to the expected processing time (typically 30-60). Applies to the queue, or to each subscription of a topic."
  type        = number
  default     = 60

  validation {
    condition     = var.lock_duration_seconds >= 5 && var.lock_duration_seconds <= 300 && floor(var.lock_duration_seconds) == var.lock_duration_seconds
    error_message = "lock_duration_seconds must be a whole number between 5 and 300 (Service Bus maximum is 5 minutes)."
  }
}

variable "default_message_ttl" {
  description = "Default message time-to-live, ISO 8601 duration (e.g. \"P14D\")."
  type        = string
  default     = "P14D"
}

variable "max_delivery_count" {
  description = "Delivery attempts before a message is dead-lettered (poison-message protection)."
  type        = number
  default     = 10

  validation {
    condition     = var.max_delivery_count >= 1 && var.max_delivery_count <= 100
    error_message = "max_delivery_count must be between 1 and 100."
  }
}

variable "requires_session" {
  description = "Enable sessions only for ordered processing. With sessions, useful parallelism is capped by the number of active sessions, so keep the KEDA maxReplicaCount in line with it."
  type        = bool
  default     = false
}

variable "requires_duplicate_detection" {
  description = "Enable only where producers set reliable MessageIds. Cannot be changed after creation."
  type        = bool
  default     = false
}

variable "duplicate_detection_window" {
  description = "Duplicate detection history window, ISO 8601 duration. Only used when requires_duplicate_detection is true."
  type        = string
  default     = "PT10M"
}

# Per-entity partitioning is intentionally NOT exposed: on Premium,
# partitioning is a namespace-level setting (premium_messaging_partitions)
# fixed when the namespace is created.

variable "subscriptions" {
  description = "Topic subscriptions to create, keyed by consumer slug. Each becomes sub-<consumer>. Must be empty for queues."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.subscriptions : can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", s)) && length(s) <= 46])
    error_message = "Each subscription consumer slug must be lowercase alphanumerics/hyphens and at most 46 characters (subscription names are limited to 50 including the sub- prefix)."
  }
}

# ---------------------------------------------------------------------------
# Data-plane access. One entry per workload identity. Separate producer and
# consumer workloads on the same entity get separate entries, each with the
# narrowest scope that serves its access_mode:
#   queue  + sender   -> Data Sender   @ /queues/<q>
#   queue  + receiver -> Data Receiver @ /queues/<q>
#   topic  + sender   -> Data Sender   @ /topics/<t>
#   topic  + receiver -> Data Receiver @ /topics/<t>/subscriptions/<s>
# Data Receiver is never granted at topic scope: that would allow receiving
# from every subscription of the topic, including other consumers'.
# Data Owner is never granted to workloads.
# ---------------------------------------------------------------------------

variable "access_grants" {
  description = "Map of grant key => { principal_id, access_mode, subscription }. access_mode is sender, receiver or sender_receiver. subscription (a consumer slug from var.subscriptions) is required for topic receivers and forbidden otherwise."
  type = map(object({
    principal_id = string
    access_mode  = string
    subscription = optional(string)
  }))

  validation {
    condition     = alltrue([for g in values(var.access_grants) : contains(["sender", "receiver", "sender_receiver"], g.access_mode)])
    error_message = "access_mode must be sender, receiver or sender_receiver."
  }

  validation {
    condition     = alltrue([for g in values(var.access_grants) : can(regex("^[0-9a-fA-F-]{36}$", g.principal_id))])
    error_message = "principal_id must be an Entra object ID (GUID)."
  }
}
