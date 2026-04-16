#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configurable variables
# =========================
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-operators}"
SUBSCRIPTION_NAME="${SUBSCRIPTION_NAME:-openshift-gitops-operator}"
PACKAGE_NAME="${PACKAGE_NAME:-openshift-gitops-operator}"
CHANNEL="${CHANNEL:-latest}"
SOURCE="${SOURCE:-redhat-operators}"
SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-openshift-marketplace}"

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
ARGOCD_INSTANCE_NAME="${ARGOCD_INSTANCE_NAME:-openshift-gitops}"
ARGOCD_ROUTE_NAME="${ARGOCD_ROUTE_NAME:-${ARGOCD_INSTANCE_NAME}-server}"

BOOTSTRAP_APP_NAME="${BOOTSTRAP_APP_NAME:-root-app}"
BOOTSTRAP_REPO_URL="${BOOTSTRAP_REPO_URL:-https://github.com/your-org/gitops-repo.git}"
BOOTSTRAP_REPO_BRANCH="${BOOTSTRAP_REPO_BRANCH:-main}"
BOOTSTRAP_REPO_PATH="${BOOTSTRAP_REPO_PATH:-bootstrap}"
BOOTSTRAP_DEST_NAMESPACE="${BOOTSTRAP_DEST_NAMESPACE:-openshift-gitops}"

TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"

# =========================
# Helpers
# =========================
log() {
  echo "[$(date '+%F %T')] $*"
}

wait_for() {
  local description="$1"
  local cmd="$2"
  local timeout="$3"

  local end=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$end" ]; do
    if eval "$cmd" >/dev/null 2>&1; then
      log "Ready: ${description}"
      return 0
    fi
    sleep "${SLEEP_SECONDS}"
  done

  log "Timeout waiting for: ${description}"
  return 1
}

# =========================
# Preconditions
# =========================
log "Checking cluster access..."
oc whoami >/dev/null
log "Connected to: $(oc whoami --show-server)"

TMP_SUB="$(mktemp)"
TMP_ARGOCD="$(mktemp)"
TMP_APP="$(mktemp)"
trap 'rm -f "$TMP_SUB" "$TMP_ARGOCD" "$TMP_APP"' EXIT

log "Checking package manifest for ${PACKAGE_NAME}..."
oc get packagemanifest "${PACKAGE_NAME}" >/dev/null 2>&1

log "Available channels:"
oc get packagemanifest "${PACKAGE_NAME}" -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'

if ! oc get packagemanifest "${PACKAGE_NAME}" -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}' | grep -qx "${CHANNEL}"; then
  log "Channel '${CHANNEL}' is not valid for package '${PACKAGE_NAME}'."
  exit 1
fi


# =========================
# 1. Install GitOps operator
# =========================
cat > "${TMP_SUB}" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUBSCRIPTION_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: ${PACKAGE_NAME}
  source: ${SOURCE}
  sourceNamespace: ${SOURCE_NAMESPACE}
EOF

if oc get subscriptions.operators.coreos.com "${SUBSCRIPTION_NAME}" -n openshift-operators >/dev/null 2>&1; then
  echo "GitOps operator already installed in openshift-operators, reusing it."
  OPERATOR_NAMESPACE="openshift-operators"
elif oc get subscriptions.operators.coreos.com "${SUBSCRIPTION_NAME}" -n openshift-gitops-operator >/dev/null 2>&1; then
  echo "GitOps operator already installed in openshift-gitops-operator, reusing it."
  OPERATOR_NAMESPACE="openshift-gitops-operator"
else
  echo "No existing GitOps operator subscription found, installing..."
  # apply subscription manifest here
  log "Applying OpenShift GitOps operator subscription..."
  oc apply -f "${TMP_SUB}"
fi

log "Waiting for Subscription to resolve installedCSV..."

end=$((SECONDS + TIMEOUT_SECONDS))
while [ $SECONDS -lt $end ]; do
  INSTALLED_CSV="$(oc get subscriptions.operators.coreos.com "${SUBSCRIPTION_NAME}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  CURRENT_CSV="$(oc get subscriptions.operators.coreos.com "${SUBSCRIPTION_NAME}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)"

  echo "currentCSV=${CURRENT_CSV:-<empty>} installedCSV=${INSTALLED_CSV:-<empty>}"

  if [ -n "${INSTALLED_CSV}" ]; then
    log "Subscription resolved installedCSV=${INSTALLED_CSV}"
    break
  fi

  echo "---- Subscription conditions ----"
  oc get subscriptions.operators.coreos.com "${SUBSCRIPTION_NAME}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" : "}{.reason}{" : "}{.message}{"\n"}{end}' || true
  echo "---------------------------------"

  sleep "${SLEEP_SECONDS}"
done

if [ -z "${INSTALLED_CSV:-}" ]; then
  log "Subscription never resolved an installedCSV."
  oc get subscriptions.operators.coreos.com "${SUBSCRIPTION_NAME}" -n "${OPERATOR_NAMESPACE}" -o yaml || true
  oc get installplan -n "${OPERATOR_NAMESPACE}" || true
  oc get csv -n "${OPERATOR_NAMESPACE}" || true
  exit 1
fi

# =========================
# 2. Create namespace
# =========================
log "Ensuring namespace ${ARGOCD_NAMESPACE} exists..."
oc get namespace "${ARGOCD_NAMESPACE}" >/dev/null 2>&1 || oc create namespace "${ARGOCD_NAMESPACE}"

# =========================
# 3. Deploy Argo CD instance
# =========================
cat > "${TMP_ARGOCD}" <<EOF
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: ${ARGOCD_INSTANCE_NAME}
  namespace: ${ARGOCD_NAMESPACE}
spec:
  server:
    route:
      enabled: true
  sso:
    provider: dex
    dex:
      openShiftOAuth: true
EOF

log "Deploying Argo CD instance ${ARGOCD_INSTANCE_NAME}..."
oc apply -f "${TMP_ARGOCD}"

log "Waiting for Argo CD instance to become Available..."

end=$((SECONDS + TIMEOUT_SECONDS))
while [ $SECONDS -lt $end ]; do
  PHASE="$(oc get argocd "${ARGOCD_INSTANCE_NAME}" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  HOST="$(oc get argocd "${ARGOCD_INSTANCE_NAME}" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.host}' 2>/dev/null || true)"

  echo "phase=${PHASE:-<empty>} host=${HOST:-<empty>}"

  if [ "${PHASE}" = "Available" ]; then
    log "Argo CD instance is Available"
    break
  fi

  oc get pods -n "${ARGOCD_NAMESPACE}" || true
  sleep "${SLEEP_SECONDS}"
done

if [ "${PHASE:-}" != "Available" ]; then
  log "Argo CD instance did not become Available."
  oc get argocd "${ARGOCD_INSTANCE_NAME}" -n "${ARGOCD_NAMESPACE}" -o yaml || true
  oc get pods -n "${ARGOCD_NAMESPACE}" || true
  oc get events -n "${ARGOCD_NAMESPACE}" --sort-by=.lastTimestamp || true
  exit 1
fi

ARGOCD_ROUTE="$(oc get route "${ARGOCD_ROUTE_NAME}" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.spec.host}')"
log "Argo CD route: https://${ARGOCD_ROUTE}"

# =========================
# 4. Grant cluster-admin
# =========================
log "Granting cluster-admin to Argo CD application controller..."
oc adm policy add-cluster-role-to-user cluster-admin \
  -z "${ARGOCD_INSTANCE_NAME}-argocd-application-controller" \
  -n "${ARGOCD_NAMESPACE}"

# =========================
# 5. Bootstrap Argo CD app
# =========================
cat > "${TMP_APP}" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${BOOTSTRAP_APP_NAME}
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: default
  source:
    repoURL: ${BOOTSTRAP_REPO_URL}
    targetRevision: ${BOOTSTRAP_REPO_BRANCH}
    path: ${BOOTSTRAP_REPO_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${BOOTSTRAP_DEST_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

log "Applying bootstrap application ${BOOTSTRAP_APP_NAME}..."
oc apply -f "${TMP_APP}"

log "Deployment complete."
echo
echo "Argo CD URL: https://${ARGOCD_ROUTE}"
echo
oc get application "${BOOTSTRAP_APP_NAME}" -n "${ARGOCD_NAMESPACE}" || true
