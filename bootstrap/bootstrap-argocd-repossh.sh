#!/usr/bin/env bash
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
SECRET_NAME="${SECRET_NAME:-gitops-repo-ssh}"
REPO_URL="${REPO_URL:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"

if [[ -z "${REPO_URL}" || -z "${SSH_KEY_FILE}" ]]; then
  echo "Usage:"
  echo "  REPO_URL=git@github.com:<user>/<repo>.git SSH_KEY_FILE=/path/to/private_key $0"
  exit 1
fi

if [[ ! -f "${SSH_KEY_FILE}" ]]; then
  echo "SSH key file not found: ${SSH_KEY_FILE}"
  exit 1
fi

SSH_KEY_CONTENT="$(cat "${SSH_KEY_FILE}")"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${REPO_URL}
  sshPrivateKey: |
$(sed 's/^/    /' "${SSH_KEY_FILE}")
EOF

echo "SSH repository secret ${SECRET_NAME} applied to ${ARGOCD_NAMESPACE}"