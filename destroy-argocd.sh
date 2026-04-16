#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configurable variables
# =========================
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-gitops-operator}"
SUBSCRIPTION_NAME="${SUBSCRIPTION_NAME:-openshift-gitops-operator}"
PACKAGE_NAME="${PACKAGE_NAME:-openshift-gitops-operator}"

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
ARGOCD_INSTANCE_NAME="${ARGOCD_INSTANCE_NAME:-openshift-gitops}"
GITOPS_SERVICE_NAME="${GITOPS_SERVICE_NAME:-cluster}"
BOOTSTRAP_APP_NAME="${BOOTSTRAP_APP_NAME:-root-app}"

DELETE_OPERATOR_NAMESPACE="${DELETE_OPERATOR_NAMESPACE:-false}"
DELETE_ARGOCD_NAMESPACE="${DELETE_ARGOCD_NAMESPACE:-false}"
DELETE_CSVS="${DELETE_CSVS:-true}"

TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"

# =========================
# Helpers
# =========================
log() {
  echo "[$(date '+%F %T')] $*"
}

exists() {
  local kind="$1"
  local name="$2"
  local ns="${3:-}"
  if [ -n "$ns" ]; then
    oc get "$kind" "$name" -n "$ns" >/dev/null 2>&1
  else
    oc get "$kind" "$name" >/dev/null 2>&1
  fi
}

wait_for_gone() {
  local description="$1"
  local cmd="$2"
  local timeout="$3"

  local end=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$end" ]; do
    if ! eval "$cmd" >/dev/null 2>&1; then
      log "Removed: ${description}"
      return 0
    fi
    sleep "${SLEEP_SECONDS}"
  done

  log "Timeout waiting for removal of: ${description}"
  return 1
}

patch_finalizers_if_exists() {
  local kind="$1"
  local name="$2"
  local ns="$3"

  if exists "$kind" "$name" "$ns"; then
    log "Removing finalizers from ${kind}/${name} in ${ns}..."
    oc patch "$kind" "$name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' || true
  fi
}

# =========================
# Preconditions
# =========================
log "Checking cluster access..."
oc whoami >/dev/null
log "Connected to: $(oc whoami --show-server)"

# =========================
# 1. Delete bootstrap application
# =========================
if exists application "${BOOTSTRAP_APP_NAME}" "${ARGOCD_NAMESPACE}"; then
  log "Deleting bootstrap application ${BOOTSTRAP_APP_NAME}..."
  oc delete application "${BOOTSTRAP_APP_NAME}" -n "${ARGOCD_NAMESPACE}" --ignore-not-found=true || true
  wait_for_gone \
    "Application ${BOOTSTRAP_APP_NAME}" \
    "oc get application ${BOOTSTRAP_APP_NAME} -n ${ARGOCD_NAMESPACE}" \
    "${TIMEOUT_SECONDS}" || true
fi

# =========================
# 2. Delete remaining child resources
# =========================
log "Deleting remaining Argo CD child resources..."
oc delete application --all -n "${ARGOCD_NAMESPACE}" --ignore-not-found=true || true
oc delete applicationset --all -n "${ARGOCD_NAMESPACE}" --ignore-not-found=true || true
oc delete appproject --all -n "${ARGOCD_NAMESPACE}" --ignore-not-found=true || true

sleep 5

for app in $(oc get application -n "${ARGOCD_NAMESPACE}" -o name 2>/dev/null || true); do
  oc patch "${app}" -n "${ARGOCD_NAMESPACE}" --type=merge -p '{"metadata":{"finalizers":[]}}' || true
done

for appset in $(oc get applicationset -n "${ARGOCD_NAMESPACE}" -o name 2>/dev/null || true); do
  oc patch "${appset}" -n "${ARGOCD_NAMESPACE}" --type=merge -p '{"metadata":{"finalizers":[]}}' || true
done

for proj in $(oc get appproject -n "${ARGOCD_NAMESPACE}" -o name 2>/dev/null || true); do
  oc patch "${proj}" -n "${ARGOCD_NAMESPACE}" --type=merge -p '{"metadata":{"finalizers":[]}}' || true
done

# =========================
# 3. Delete GitopsService first
# =========================
if exists gitopsservice "${GITOPS_SERVICE_NAME}" "${ARGOCD_NAMESPACE}"; then
  log "Deleting GitopsService ${GITOPS_SERVICE_NAME}..."
  oc delete gitopsservice "${GITOPS_SERVICE_NAME}" -n "${ARGOCD_NAMESPACE}" --ignore-not-found=true || true

  if ! wait_for_gone \
    "GitopsService ${GITOPS_SERVICE_NAME}" \
    "oc get gitopsservice ${GITOPS_SERVICE_NAME} -n ${ARGOCD_NAMESPACE}" \
    "${TIMEOUT_SECONDS}"; then
    patch_finalizers_if_exists gitopsservice "${GITOPS_SERVICE_NAME}" "${ARGOCD_NAMESPACE}"
    wait_for_gone \
      "GitopsService ${GITOPS_SERVICE_NAME}" \
      "oc get gitopsservice ${GITOPS_SERVICE_NAME} -n ${ARGOCD_NAMESPACE}" \
      "${TIMEOUT_SECONDS}" || true
  fi
fi

# =========================
# 4. Delete Argo CD instance if still present
# =========================
if exists argocd "${ARGOCD_INSTANCE_NAME}" "${ARGOCD_NAMESPACE}"; then
  log "Deleting Argo CD instance ${ARGOCD_INSTANCE_NAME}..."
  oc delete argocd "${ARGOCD_INSTANCE_NAME}" -n "${ARGOCD_NAMESPACE}" --ignore-not-found=true || true

  if ! wait_for_gone \
    "ArgoCD ${ARGOCD_INSTANCE_NAME}" \
    "oc get argocd ${ARGOCD_INSTANCE_NAME} -n ${ARGOCD_NAMESPACE}" \
    "${TIMEOUT_SECONDS}"; then
    patch_finalizers_if_exists argocd "${ARGOCD_INSTANCE_NAME}" "${ARGOCD_NAMESPACE}"
    wait_for_gone \
      "ArgoCD ${ARGOCD_INSTANCE_NAME}" \
      "oc get argocd ${ARGOCD_INSTANCE_NAME} -n ${ARGOCD_NAMESPACE}" \
      "${TIMEOUT_SECONDS}" || true
  fi
fi

# =========================
# 5. Remove cluster-admin binding
# =========================
log "Removing cluster-admin from Argo CD application controller..."
oc adm policy remove-cluster-role-from-user cluster-admin \
  -z "${ARGOCD_INSTANCE_NAME}-argocd-application-controller" \
  -n "${ARGOCD_NAMESPACE}" || true

# =========================
# 6. Uninstall operator subscription
# =========================
if exists subscriptions.operators.coreos.com "${SUBSCRIPTION_NAME}" "${OPERATOR_NAMESPACE}"; then
  log "Deleting operator subscription ${SUBSCRIPTION_NAME}..."
  oc delete subscriptions.operators.coreos.com "${SUBSCRIPTION_NAME}" -n "${OPERATOR_NAMESPACE}" --ignore-not-found=true || true

  wait_for_gone \
    "Subscription ${SUBSCRIPTION_NAME}" \
    "oc get subscriptions.operators.coreos.com ${SUBSCRIPTION_NAME} -n ${OPERATOR_NAMESPACE}" \
    "${TIMEOUT_SECONDS}" || true
fi

# =========================
# 7. Optionally delete related CSVs
# =========================
if [ "${DELETE_CSVS}" = "true" ]; then
  log "Deleting related ClusterServiceVersions..."
  for csv in $(oc get csv -n "${OPERATOR_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep gitops || true); do
    oc delete csv "${csv}" -n "${OPERATOR_NAMESPACE}" --ignore-not-found=true || true
  done
fi

# =========================
# 8. Optional namespace cleanup
# =========================
if [ "${DELETE_OPERATOR_NAMESPACE}" = "true" ]; then
  log "Deleting operator namespace ${OPERATOR_NAMESPACE}..."
  oc delete namespace "${OPERATOR_NAMESPACE}" --ignore-not-found=true || true
fi

if [ "${DELETE_ARGOCD_NAMESPACE}" = "true" ]; then
  log "Deleting Argo CD namespace ${ARGOCD_NAMESPACE}..."
  oc delete namespace "${ARGOCD_NAMESPACE}" --ignore-not-found=true || true
fi


# Correct namespace for AllNamespaces installation
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-operators}"

# Remove Subscription
oc delete subscriptions.operators.coreos.com "${SUBSCRIPTION_NAME}" \
  -n "${OPERATOR_NAMESPACE}" --ignore-not-found=true

# Remove CSV
CSV_NAME=$(oc get csv -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift GitOps")].metadata.name}')
if [ -n "$CSV_NAME" ]; then
  oc delete csv "$CSV_NAME" -n "${OPERATOR_NAMESPACE}" --ignore-not-found=true
fi

# Remove any InstallPlans
oc delete installplan --all -n "${OPERATOR_NAMESPACE}" --ignore-not-found=true


log "Destroy complete."

echo
echo "Post-checks:"
oc get gitopsservice -n "${ARGOCD_NAMESPACE}" || true
oc get argocd -n "${ARGOCD_NAMESPACE}" || true
oc get subscriptions.operators.coreos.com -n "${OPERATOR_NAMESPACE}" || true
oc get csv -n "${OPERATOR_NAMESPACE}" || true

