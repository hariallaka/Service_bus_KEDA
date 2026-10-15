#!/usr/bin/env bash
# End-to-end verification that KEDA is actually driving scale-out/scale-in
# for a tenant's Service Bus consumer Deployment. Does not create or modify
# any Azure resources - it only sends test messages (via
# send-test-messages.py, AAD-authenticated) and observes the Deployment /
# HPA / ScaledObject that are already deployed via the Helm chart.
#
# Usage:
#   ./verify-keda-scaling.sh -n <namespace> -d <deployment> \
#       -s <servicebus-namespace-fqdn> (-q <queue-name> | -t <topic-name>) \
#       [-c <message-count>] \
#       [--skip-scale-down-check]
#
# Requires: kubectl (context pointed at the target AKS cluster), python3
# with the packages in requirements.txt (or `pip install -r requirements.txt`
# run beforehand), and an Azure identity (az login, or federated OIDC in CI)
# with send rights on the target queue.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE=""
DEPLOYMENT=""
SB_FQDN=""
QUEUE_NAME=""
TOPIC_NAME=""
MESSAGE_COUNT=20
SCALE_UP_TIMEOUT=180     # seconds to wait for at least 1 replica
POLL_INTERVAL=5          # seconds between status checks
SKIP_SCALE_DOWN_CHECK=false
SCALE_DOWN_TIMEOUT=600   # seconds to wait for scale back to baseline (cooldownPeriod + slack)

usage() {
  grep '^#' "$0" | sed -e 's/^#//' -e '1d'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NAMESPACE="$2"; shift 2 ;;
    -d) DEPLOYMENT="$2"; shift 2 ;;
    -s) SB_FQDN="$2"; shift 2 ;;
    -q) QUEUE_NAME="$2"; shift 2 ;;
    -t) TOPIC_NAME="$2"; shift 2 ;;
    -c) MESSAGE_COUNT="$2"; shift 2 ;;
    --scale-up-timeout) SCALE_UP_TIMEOUT="$2"; shift 2 ;;
    --scale-down-timeout) SCALE_DOWN_TIMEOUT="$2"; shift 2 ;;
    --skip-scale-down-check) SKIP_SCALE_DOWN_CHECK=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

for required in NAMESPACE DEPLOYMENT SB_FQDN; do
  if [[ -z "${!required}" ]]; then
    echo "Missing required argument for ${required}" >&2
    usage
  fi
done

if [[ -z "${QUEUE_NAME}" && -z "${TOPIC_NAME}" ]] || [[ -n "${QUEUE_NAME}" && -n "${TOPIC_NAME}" ]]; then
  echo "Specify exactly one of -q <queue-name> or -t <topic-name>" >&2
  usage
fi
if [[ -n "${QUEUE_NAME}" ]]; then
  TARGET="${QUEUE_NAME}"; TARGET_ARGS=(--queue-name "${QUEUE_NAME}")
else
  TARGET="${TOPIC_NAME}"; TARGET_ARGS=(--topic-name "${TOPIC_NAME}")
fi

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

get_replicas() {
  kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0
}

log "Checking ScaledObject/TriggerAuthentication exist in namespace ${NAMESPACE}..."
kubectl get scaledobject -n "${NAMESPACE}" -o wide
kubectl get triggerauthentication -n "${NAMESPACE}" -o wide

BASELINE_REPLICAS="$(get_replicas)"
BASELINE_REPLICAS="${BASELINE_REPLICAS:-0}"
log "Baseline ready replicas for ${DEPLOYMENT}: ${BASELINE_REPLICAS}"

log "Sending ${MESSAGE_COUNT} test messages to ${TARGET}@${SB_FQDN}..."
python3 "${SCRIPT_DIR}/send-test-messages.py" \
  --namespace-fqdn "${SB_FQDN}" \
  "${TARGET_ARGS[@]}" \
  --count "${MESSAGE_COUNT}"

log "Waiting up to ${SCALE_UP_TIMEOUT}s for ${DEPLOYMENT} to scale above baseline..."
elapsed=0
scaled_up=false
while [[ ${elapsed} -lt ${SCALE_UP_TIMEOUT} ]]; do
  current="$(get_replicas)"
  current="${current:-0}"
  log "  replicas=${current} (baseline=${BASELINE_REPLICAS})"
  if [[ "${current}" -gt "${BASELINE_REPLICAS}" ]]; then
    scaled_up=true
    break
  fi
  sleep "${POLL_INTERVAL}"
  elapsed=$((elapsed + POLL_INTERVAL))
done

if [[ "${scaled_up}" != true ]]; then
  echo "FAIL: ${DEPLOYMENT} did not scale up within ${SCALE_UP_TIMEOUT}s" >&2
  kubectl describe scaledobject -n "${NAMESPACE}"
  exit 1
fi

log "PASS: scale-up confirmed."
kubectl get hpa -n "${NAMESPACE}"

if [[ "${SKIP_SCALE_DOWN_CHECK}" == true ]]; then
  log "Skipping scale-down check (--skip-scale-down-check set)."
  exit 0
fi

log "Waiting up to ${SCALE_DOWN_TIMEOUT}s for ${DEPLOYMENT} to drain back to baseline (${BASELINE_REPLICAS})..."
elapsed=0
scaled_down=false
while [[ ${elapsed} -lt ${SCALE_DOWN_TIMEOUT} ]]; do
  current="$(get_replicas)"
  current="${current:-0}"
  log "  replicas=${current} (baseline=${BASELINE_REPLICAS})"
  if [[ "${current}" -le "${BASELINE_REPLICAS}" ]]; then
    scaled_down=true
    break
  fi
  sleep "${POLL_INTERVAL}"
  elapsed=$((elapsed + POLL_INTERVAL))
done

if [[ "${scaled_down}" != true ]]; then
  echo "FAIL: ${DEPLOYMENT} did not scale back down to baseline within ${SCALE_DOWN_TIMEOUT}s" >&2
  exit 1
fi

log "PASS: scale-down confirmed. KEDA + Service Bus integration verified end-to-end."
