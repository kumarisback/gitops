#!/usr/bin/env bash
# Alert drill: take one service down on purpose, check that alerting notices,
# then bring it back and check that the alert clears. Roadmap step 08
# ("deliberately break things"). Uses only kubectl, against the current
# context: the kind lab or an EKS cluster.
#
#   ./scripts/alert-drill.sh                          # order-service in development
#   ./scripts/alert-drill.sh user-service staging
#
# 1. Scales the Deployment to 0. Its HPA stops scaling while the count is 0,
#    and ArgoCD leaves the count alone (the HPA owns it, not Git).
# 2. Waits until Alertmanager has an active ServiceUnavailable alert for it
#    (observability/base/service-alerts.yaml: 2 minutes, plus evaluation).
# 3. Restores the previous replica count, waits for the rollout, and waits
#    until the alert is no longer active.
# The service is restored even if the script fails or is interrupted.
#
# In the cloud the alert also goes to PagerDuty and Slack: check that both
# the page and the resolve message arrived. DRILL_TIMEOUT_SECONDS (default
# 600) bounds each wait.
set -euo pipefail

SERVICE="${1:-order-service}"
NAMESPACE="${2:-development}"
TIMEOUT="${DRILL_TIMEOUT_SECONDS:-600}"
# Alertmanager's v2 API through the API server's service proxy: no
# port-forward needed, only permission to proxy to services in monitoring.
ALERTS_API="/api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts"

case "${SERVICE}" in
  frontend|order-service|user-service|notification-service) ;;
  *) echo "❌ Unknown service '${SERVICE}' (frontend, order-service, user-service or notification-service)"; exit 2 ;;
esac

echo "🎯 Alert drill: ${SERVICE} in ${NAMESPACE} (context $(kubectl config current-context))"

REPLICAS="$(kubectl get deployment "${SERVICE}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')"
if [ "${REPLICAS:-0}" -eq 0 ]; then
  echo "❌ ${SERVICE} already has 0 replicas; nothing to drill."
  exit 1
fi

alert_active() {
  local alerts
  alerts="$(kubectl get --raw "${ALERTS_API}?active=true&filter=alertname%3D%22ServiceUnavailable%22&filter=deployment%3D%22${SERVICE}%22&filter=namespace%3D%22${NAMESPACE}%22")"
  [ "${alerts}" != "[]" ]
}

alert_cleared() { ! alert_active; }

# wait_for DESCRIPTION COMMAND...: poll COMMAND every 15s until it succeeds.
wait_for() {
  local description="$1"; shift
  local start="${SECONDS}"
  printf '⏳ %s' "${description}"
  until "$@"; do
    if [ $((SECONDS - start)) -ge "${TIMEOUT}" ]; then
      printf '\n❌ Not within %ss: %s\n' "${TIMEOUT}" "${description}"
      return 1
    fi
    printf '.'
    sleep 15
  done
  printf ' after %ss\n' $((SECONDS - start))
}

restored=0
restore() {
  [ "${restored}" -eq 1 ] && return 0
  restored=1
  echo "🔧 Restoring ${SERVICE} to ${REPLICAS} replicas..."
  kubectl scale deployment "${SERVICE}" -n "${NAMESPACE}" --replicas="${REPLICAS}" > /dev/null
}
trap restore EXIT

if alert_active; then
  echo "❌ ServiceUnavailable is already firing for ${SERVICE}; fix that first."
  exit 1
fi

echo "💥 Scaling ${SERVICE} from ${REPLICAS} to 0 replicas..."
kubectl scale deployment "${SERVICE}" -n "${NAMESPACE}" --replicas=0 > /dev/null
wait_for "ServiceUnavailable firing for ${SERVICE}" alert_active

restore
kubectl rollout status deployment "${SERVICE}" -n "${NAMESPACE}" --timeout="${TIMEOUT}s"
wait_for "ServiceUnavailable cleared for ${SERVICE}" alert_cleared

echo "✅ Drill passed: the outage was detected and the alert cleared after recovery."
