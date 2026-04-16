#!/usr/bin/env bash
set -euo pipefail

NS="external-secrets-config"
ACCESS_KEY="${AWS_ACCESS_KEY_ID:-}"
SECRET_KEY="${AWS_SECRET_ACCESS_KEY:-}"

if [[ -z "${ACCESS_KEY}" || -z "${SECRET_KEY}" ]]; then
  echo "Missing AWS credentials in environment variables."
  exit 1
fi

oc create namespace "${NS}" --dry-run=client -o yaml | oc apply -f -

oc create secret generic aws-secretsmanager-creds \
  -n "${NS}" \
  --from-literal=access-key-id="${ACCESS_KEY}" \
  --from-literal=secret-access-key="${SECRET_KEY}" \
  --dry-run=client -o yaml | oc apply -f -

echo "Bootstrap AWS credentials created in namespace ${NS}"