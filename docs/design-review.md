# Design review: Service Bus + KEDA in the shared landing zone

Reviewed: *Service Registry Design for Azure Service Bus and KEDA
Autoscaling* (11 pages), compared against this repository.

**Verdict: the direction is sound but the design isn't ready to approve as
written.** A shared Premium namespace, entity-level isolation, Entra
workload identity, KEDA scaling on active message count, and a
database-validated registry are the right choices. Three gaps, though, would
break tenant isolation or KEDA scaling if the design were built literally
(§2, items 1–3). The repository had the same gaps plus two bugs that would
have stopped scaling entirely. Both sides are corrected below. The repo
fixes are implemented and tested; the design changes are proposed text.

---

## 1. What the design gets right

- **One Premium namespace, isolation at entity level.** Messaging Units are
  namespace-wide, so splitting namespaces doesn't buy per-tenant throughput.
  The criteria for adding a namespace are the right ones.
- **Entra data-plane RBAC at entity scope, with SAS disabled.** This is the
  only real isolation boundary in a shared namespace, and the design
  correctly treats `disableLocalAuth=true` as a hard rule.
- **No control-plane rights for workloads.**
- **Scaling on the subscription backlog for fan-out**, not on the topic.
- **Scaling defaults** (`messageCount` 10, min 1, max 10, polling 30s,
  cooldown 300s) are conservative and sensible.
- **Registry validation and audit in the database**, with a provisioning
  status that drives reconciliation.

---

## 2. Design gaps (change before approval)

### Critical: tenant isolation

**1. The KEDA identity model isn't implementable as written, and once
implemented it creates a cross-tenant path.**
The design says the workload identity "is used by the application and the
KEDA `TriggerAuthentication`", and its example `TriggerAuthentication` has
only `provider: azure-workload`. In KEDA, that provider always
authenticates as the **keda-operator ServiceAccount**. As written, KEDA uses
its own identity, which then needs access to every tenant's entities and
breaks isolation (or scaling simply fails). The only way to honour "same
identity" is:

- every tenant UAMI gets a second federated credential for
  `system:serviceaccount:keda:keda-operator` (KEDA is self-managed in the
  `keda` namespace), created **once per tenant identity**, not per entity:
  an identity can hold only one credential per issuer and subject, and
- the tenant identity holds the receive grant on each of its entities,
  because KEDA reads queue depth as that identity, and
- each `TriggerAuthentication` sets `podIdentity.identityId` to the
  tenant's client ID.

As a result, the KEDA operator can act as **any** tenant, and the choice of
identity is made by a namespaced object that the tenant writes. Tenant B can
put tenant A's client ID (not a secret) in its own `TriggerAuthentication`.

*Proposed design text:* add an "Admission control" section. A cluster-wide
ValidatingAdmissionPolicy requires `identityId` to equal the identity
recorded on the tenant Namespace by onboarding, forbids secret-based auth,
`identityTenantId` overrides and `ClusterTriggerAuthentication`, and
enforces entity prefixes and scaling caps. Tenants get no RBAC on Namespace
objects or `ClusterTriggerAuthentication`. The KEDA operator's own identity
has no Service Bus roles. Implemented in
`platform/admission/keda-tenant-guardrails.yaml`.

*Agreed:* this per-tenant model ("KEDA polls as the tenant") is the
platform default. The alternative, one shared KEDA identity with
entity-scoped grants and no per-tenant credentials, was rejected: it would
leave the admission policy as the only control on the scaling path.
Implemented in `terraform/tenant-keda-identity` (once per tenant).

*Residual risk to record:* the KEDA operator is now a high-value component
that can receive messages from every tenant's entity (Data Receiver
includes receive, not just read). If that's not acceptable, scale with the
`azure-monitor` scaler on the `ActiveMessages` metric with *Monitoring
Reader*. KEDA then has no data-plane access at all, at the cost of
roughly 1–3 minutes of metric latency. Decide this explicitly.

**2. Naming allows prefix collisions between tenants. Resolved by using
the tenant ID.**
With free-text tenant names, `q-<tenant>-<purpose>` is ambiguous: tenant
`acme` + purpose `x-orders` and tenant `acme-x` + purpose `orders` both
produce `q-acme-x-orders`. That breaks "one owner per entity" and any
prefix-based ownership check.
*Agreed:* put the platform tenant ID in the name. Its format is
`APP-<number>-UC<nn>`, one ID per application use case. *Proposed design
text:*
- Naming: `q-<tenantid>-<purpose>`, `t-<tenantid>-<purpose>`,
  `sub-<consumer>`, e.g. `q-app-1234-uc01-orders`.
- Tenant ID validated as `^APP-[0-9]{1,8}-UC[0-9]{2}$` and stored in that
  canonical uppercase form; names use the lowercase form. Service Bus names
  are case-insensitive but the registry's uniqueness is case-sensitive, and
  Kubernetes names must be lowercase.
- Because the ID has a fixed structure, one tenant's prefix can never be a
  prefix of another's (`q-app-1234-uc01-` vs `q-app-12345-…` or
  `q-app-1234-uc02-…`), so prefix checks are exact. This holds only while
  `UC` stays exactly two digits; if use cases may exceed 99, widen the
  pattern for every tenant at once, not per tenant.
- `purpose` `^[a-z0-9]+(-[a-z0-9]+)*$` up to 40 characters; subscription
  consumer up to 46 characters (subscription names are limited to 50).
  Longest queue name ≈ 60 characters, well under the 260 limit.
- The registry's `tenant_id` should be a foreign key to the existing tenant
  table, so only onboarded tenants can own entities.
- The isolation unit is the use case: each `APP-…-UCnn` has its own
  identity and Kubernetes namespace. See §5 for the alternative.

**3. No networking section.** For a landing-zone service this is a major
omission. *Proposed additions:*
- Private endpoint + `privatelink.servicebus.windows.net` DNS linked to
  spoke VNets; public network access disabled; minimum TLS 1.2.
- AKS egress to the private endpoint on 5671 and 443 (not 5672), **and to
  Microsoft Entra ID on 443**. Workload identity can't exchange tokens
  without it, and that is the most common cause of a "permission" failure
  that is really a network failure.
- The KEDA operator in the `keda` namespace needs the same egress.
- Per-tenant default-deny NetworkPolicy.

### High: correctness and governance

**4. Entity model can't represent producer + consumer.** Putting
`access_mode` on the entity row means a queue with a producer workload and
a separate consumer workload can't be registered, and "must not be assigned
to multiple owners" then conflicts with legitimate access. *Proposed:*
separate **entity** (one owning service) from **access grant** (one row per
workload identity with `access_mode`, principal/client ID, Kubernetes
namespace, ServiceAccount). Implemented in `registry/001_servicebus_keda.sql`.

**5. Topic-scope receive must be forbidden explicitly.** The scope table
lists topic scope for send-side access, but nothing forbids *Data Receiver*
at topic scope, which grants receive on **every** subscription of that
topic. *Proposed rule:* receive is granted only at queue or subscription
scope.

**6. `rbac_scope` must be derived, not stored from input.** A free-text
scope in the registry is a privilege-escalation vector: a scope truncated to
the namespace grants access to every tenant. *Proposed:* compute the scope
from the approved namespace's resource ID plus the entity path, and store
it as an array because a topic `sender_receiver` needs two scopes.

**7. Data Owner for platform identities.** Data Owner on the shared
namespace gives that identity send/receive on all tenants' data. Entity
creation is a control-plane (ARM) operation. *Proposed:* the provisioning
identity gets a custom role with
`Microsoft.ServiceBus/namespaces/{queues,topics,topics/subscriptions}/*`
write/delete plus role-assignment write constrained by an ABAC condition to
the two Service Bus data roles. No platform identity gets Data Owner.

**8. Capacity numbers.** The "1,000-entity namespace ceiling" is not the
Premium limit. Premium allows **1,000 entities per Messaging Unit**, and
**subscriptions count** towards it. At 4 MUs the ceiling is 4,000, and
fan-out designs reach it through subscriptions faster than the queue/topic
count suggests. *Proposed trigger:* "total queues + topics + subscriptions
above 80% of 1,000 × MU".

**9. Noisy-neighbour controls.** KEDA caps protect downstream systems, not
the namespace. A single producer can saturate the shared MUs for everyone.
*Proposed additions:* per-entity incoming-message and size alerts,
Premium MU autoscale with a ceiling, a per-tenant entity-count quota in the
registry, and a polling-interval floor (15s). Every KEDA poll is a
management-API call: about 1,000 ScaledObjects at 30s is ~33 req/s on the
namespace, and throttling surfaces in KEDA as
`no CountDetails element`.

**10. Lifecycle and reconciliation rules are incomplete.**
- Define the allowed status transitions. Proposed:
  requested→provisioned|failed|retired; provisioned→requested|suspended|failed|retired;
  failed→requested|retired; suspended→requested|provisioned|retired;
  retired is terminal.
- Any spec change resets status to `requested` (re-queue for
  reconciliation).
- **Retire order:** KEDA objects → role assignments → subscriptions → entity.
  A role assignment on a deleted scope is orphaned, not revoked.
- Records are retired, never deleted, so the audit trail stays complete.
- The audit must capture the requesting human or pipeline, not the shared
  database login.

### Medium: clarifications

11. **`maxReplicaCount` must be mandatory.** KEDA defaults it to 100 when
    omitted.
12. **The KEDA `namespace` field is the short name** (`sb-daas`, as in the
    design's examples). State it explicitly: an FQDN there produces a
    broken endpoint, and the repo had exactly this bug.
13. **Sessions:** effective parallelism equals the number of active
    sessions; `maxReplicaCount` should not exceed it.
14. **Partitioning** is a namespace-level choice on Premium
    (`premium_messaging_partitions`), fixed at creation. Decide it in the
    namespace design; it can't be set per entity.
15. **Cross-tenant fan-out** (tenant B subscribing to tenant A's topic) is
    neither allowed nor forbidden by the design. The implementation forbids
    it, since the subscription must sit under the tenant's own `t-<tenantid>-`
    topic. If it's needed, model it as a grant approved by the topic owner.
16. **Registry fields to add:** `tenant`, `purpose`, `environment`,
    `max_delivery_count`, `requires_session`, `requires_duplicate_detection`,
    workload identity principal/client ID, Kubernetes namespace and
    ServiceAccount, `trigger_authentication_name`, plus an approved-namespace
    table (SKU, local-auth-disabled flag, active flag) and per-environment
    platform limits.
17. **Validation checklist:** add "KEDA operator federated credential
    exists for the tenant identity", "admission policy rejects a
    `TriggerAuthentication` naming another tenant's identity", and "Entra
    and private-endpoint egress verified from both the tenant namespace and
    the `keda` namespace".

---

## 3. Repository issues found and fixed

| # | Issue in the repo before this change | Impact | Fix |
|---|---|---|---|
| R1 | `TriggerAuthentication` used `identityOwner: workload` | Field is AWS-only, so KEDA used its own identity. The README's per-tenant isolation claim for the scaling path was false, and scaling failed unless the operator had broad access. | `identityId` = tenant client ID; KEDA trust created once per tenant (`terraform/tenant-keda-identity`); admission policy |
| R2 | ScaledObject `namespace` was the FQDN | KEDA built `x.servicebus.windows.net.servicebus.windows.net`, so **no scaling at all** | Short name; chart and policy reject FQDNs |
| R3 | No admission control | Cross-tenant identity use via `identityId` (see §2.1) | `platform/admission` + tests |
| R4 | Queue only, free-form names, unused `tenant_name` | Couldn't express the design's topic/subscription model or naming | Queue or topic + subscriptions; names generated from tenant ID (`APP-<number>-UC<nn>`) and purpose |
| R5 | Only receive (+ optional send) for one identity | No separate producer/consumer grants, no subscription-scoped receive | `access_grants` map with exact-scope expansion |
| R6 | Per-queue `enable_partitioning` | Not valid per entity on Premium | Removed |
| R7 | No guardrails on size, lock, replicas, polling | Unsafe values accepted | Terraform validations, chart schema + checks, policy, registry |
| R8 | NetworkPolicy allowed 5672 (plaintext AMQP), port 53 to any pod in any namespace, and `- {}` (any destination) by default | Plaintext path; lateral reach; open egress by default | TLS ports only, DNS to kube-dns only, CIDRs required unless public is explicitly enabled |
| R9 | NetworkPolicy had no Entra ID egress | With a private-endpoint CIDR, token exchange is blocked and auth fails | Entra rule on 443 to public ranges only |
| R10 | Deployment set `replicas`, image `:latest`, no securityContext | Every `helm upgrade` reset the scale; unpinned image; root allowed | `replicas` omitted, pinned example tags, restricted securityContext, no API token mount |
| R11 | Design defaults not used (`min 0`, `max 20`, `messageCount 5`, polling 15) | Diverged from the approved scaling contract | Design defaults |
| R12 | Workflow interpolated `inputs.*` into `run:` | Shell injection via dispatch inputs | Inputs passed through `env:` |
| R13 | No registry implementation | Design's PostgreSQL rules unenforced | `registry/001_servicebus_keda.sql` + tests |

## 4. Verification performed

| Check | Result |
|---|---|
| `terraform validate` + `terraform test` (mock azurerm 3.117) | 10/10 pass: naming, exact scopes, topic receive at subscription scope, rejects unapproved namespace, free-text / lowercase / malformed tenant IDs, unapproved size, queue with subscriptions, topic receiver without subscription |
| `helm lint` + render, both example tenants | Pass. The 9 negative cases (FQDN, foreign queue, caps, min>max, polling, missing CIDRs, bad tenant, bad client ID, topic without subscription) fail with clear messages |
| Admission-policy CEL tests (cel-go + strings ext v2) | Rendered chart admitted. 6 TriggerAuthentication and 15 ScaledObject attack/misconfiguration cases denied, including another use case of the same app and a longer app number. 3 malformed Namespace tenant labels denied |
| Registry migration + SQL tests on PostgreSQL 16 | All pass: namespace hardening, naming, uniqueness, sizes, subscription parent type, computed scopes (tampered input overwritten), KEDA caps, status machine, re-queue on change, retire cascade, audit actor |
| Live Azure/AKS | **Not run** (no subscription access here). Run `scripts/verify-keda-scaling.sh`, and `kubectl apply --dry-run=server -f platform/admission/` on the target cluster version. In that run, confirm Data Receiver at entity scope is enough for KEDA's runtime-properties read |

## 5. Decisions needed from the team

1. Accept that the KEDA operator can receive from every tenant's entity,
   with admission control as the boundary, or switch to the Azure Monitor
   scaler so KEDA has metrics-only access (§2.1).
2. Allow or forbid cross-tenant topic subscriptions (§2.15). Currently
   forbidden.
3. ~~Who owns the KEDA federated credential?~~ Decided: KEDA polls as the
   tenant identity by default, and the platform creates the credential once
   per tenant with `terraform/tenant-keda-identity`, as part of onboarding.
4. Platform caps per environment (currently max replicas 50, `messageCount`
   ≤ 1000, polling ≥ 15s).
5. Isolation unit: one Kubernetes namespace and identity per tenant ID
   (`APP-1234-UC01`), which is what is implemented. The alternative is one
   namespace per application with several use cases inside it. Then the
   use cases share Kubernetes RBAC and network policy and can't be isolated
   from each other, and the admission policy would have to allow several
   identities and prefixes per namespace. Recommended: keep per use case.
6. Can `UC` ever exceed two digits? If so, change the pattern now, before
   any entities exist, since names can't be changed after creation.
