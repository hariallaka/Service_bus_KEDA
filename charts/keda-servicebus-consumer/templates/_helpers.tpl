{{/* Lowercase tenant ID, as used inside Azure and Kubernetes resource names. */}}
{{- define "keda-servicebus-consumer.tenantSlug" -}}
{{- lower .Values.tenant.id -}}
{{- end -}}

{{- define "keda-servicebus-consumer.labels" -}}
app.kubernetes.io/name: keda-servicebus-consumer
app.kubernetes.io/instance: {{ .Release.Name }}
tenant: {{ .Values.tenant.id }}
{{- end -}}

{{- define "keda-servicebus-consumer.scaledObjectName" -}}
{{- default (printf "so-%s" .Values.workload.deploymentName) .Values.keda.scaledObjectName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "keda-servicebus-consumer.triggerAuthName" -}}
{{- default (printf "ta-%s" .Values.workload.deploymentName) .Values.keda.triggerAuthenticationName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Cross-field guardrails that values.schema.json can't express. Rendering
fails with a clear message instead of producing an unsafe manifest.
*/}}
{{- define "keda-servicebus-consumer.validate" -}}
{{- $t := lower .Values.tenant.id -}}
{{- $sb := .Values.serviceBus -}}
{{- $s := .Values.scaling -}}
{{- $l := .Values.platformLimits -}}
{{- if contains "." $sb.namespace -}}
{{- fail "serviceBus.namespace must be the short namespace name (e.g. sb-example-shared), not the FQDN: KEDA appends the endpoint suffix itself" -}}
{{- end -}}
{{- if eq $sb.entityType "queue" -}}
{{- if not (hasPrefix (printf "q-%s-" $t) $sb.queueName) -}}
{{- fail (printf "serviceBus.queueName must follow q-%s-<purpose>" $t) -}}
{{- end -}}
{{- if or $sb.topicName $sb.subscriptionName -}}
{{- fail "a queue consumer must not set serviceBus.topicName/subscriptionName" -}}
{{- end -}}
{{- else -}}
{{- if not (hasPrefix (printf "t-%s-" $t) $sb.topicName) -}}
{{- fail (printf "serviceBus.topicName must follow t-%s-<purpose>" $t) -}}
{{- end -}}
{{- if not (hasPrefix "sub-" $sb.subscriptionName) -}}
{{- fail "a topic consumer must set serviceBus.subscriptionName (sub-<consumer>); KEDA must scale on the subscription backlog" -}}
{{- end -}}
{{- if $sb.queueName -}}
{{- fail "a topic consumer must not set serviceBus.queueName" -}}
{{- end -}}
{{- end -}}
{{- if gt (int $s.minReplicaCount) (int $s.maxReplicaCount) -}}
{{- fail "scaling.minReplicaCount must be <= scaling.maxReplicaCount" -}}
{{- end -}}
{{- if gt (int $s.maxReplicaCount) (int $l.maxReplicaCap) -}}
{{- fail (printf "scaling.maxReplicaCount exceeds the platform cap of %d" (int $l.maxReplicaCap)) -}}
{{- end -}}
{{- if gt (int $s.messageCount) (int $l.maxMessageCount) -}}
{{- fail (printf "scaling.messageCount exceeds the platform maximum of %d" (int $l.maxMessageCount)) -}}
{{- end -}}
{{- if lt (int $s.pollingIntervalSeconds) (int $l.minPollingIntervalSeconds) -}}
{{- fail (printf "scaling.pollingIntervalSeconds must be >= %d (each poll is a Service Bus management call)" (int $l.minPollingIntervalSeconds)) -}}
{{- end -}}
{{- if and .Values.networkPolicy.enabled (not .Values.networkPolicy.serviceBusEgressCIDRs) (not .Values.networkPolicy.allowPublicServiceBusEgress) -}}
{{- fail "set networkPolicy.serviceBusEgressCIDRs to the Service Bus private endpoint range, or explicitly set networkPolicy.allowPublicServiceBusEgress=true" -}}
{{- end -}}
{{- end -}}
