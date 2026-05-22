#!/usr/bin/env bash
# Deploy IBM MQ NativeHA CRR with no real certificate material in OpenShift Secrets.
#
# Real app PKI, local NativeHA TLS, and NativeHA CRR TLS are fetched from Vault by
# the init container using the same IBM MQ image as the QueueManager container.
# The throwaway self-signed Secret is only an MQ Operator admission/controller
# shim. MQ is pointed by INI to the real Vault-injected certificate labels.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VAULT_ADDR="${VAULT_ADDR:-https://vault.mycompany.org:8200}"
VAULT_TOKEN="${1:-${VAULT_TOKEN:-}}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-kv}"
SECRET_NAME="${SECRET_NAME:-tmpqm001-admission-shim}"
NAMESPACES=("tmpqm001-use" "tmpqm001-usw")

command -v oc &>/dev/null || { echo "ERROR: 'oc' not found in PATH" >&2; exit 1; }

for ns in "${NAMESPACES[@]}"; do
  oc get namespace "${ns}" >/dev/null 2>&1 || oc create namespace "${ns}"

  echo "==> Creating throwaway admission shim Secret '${SECRET_NAME}' in namespace '${ns}'"
  tmpdir="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${tmpdir}/ca.key" \
    -out "${tmpdir}/ca.crt" \
    -days 1 \
    -subj "/CN=${SECRET_NAME}.${ns}.dummy-ca.invalid" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes \
    -keyout "${tmpdir}/tls.key" \
    -out "${tmpdir}/tls.csr" \
    -subj "/CN=${SECRET_NAME}.${ns}.dummy-leaf.invalid" >/dev/null 2>&1
  openssl x509 -req \
    -in "${tmpdir}/tls.csr" \
    -CA "${tmpdir}/ca.crt" \
    -CAkey "${tmpdir}/ca.key" \
    -CAcreateserial \
    -out "${tmpdir}/tls.crt" \
    -days 1 >/dev/null 2>&1
  oc create secret generic "${SECRET_NAME}" \
    -n "${ns}" \
    --from-file=tls.key="${tmpdir}/tls.key" \
    --from-file=tls.crt="${tmpdir}/tls.crt" \
    --from-file=ca.crt="${tmpdir}/ca.crt" \
    --dry-run=client \
    -o yaml | oc apply -f -
  rm -rf "${tmpdir}"
  oc annotate secret "${SECRET_NAME}" -n "${ns}" \
    note="Throwaway one-day self-signed shim only. Real MQ TLS material is injected from Vault by init container." \
    --overwrite
  oc label secret "${SECRET_NAME}" -n "${ns}" \
    app.kubernetes.io/managed-by=manual-lab \
    mq.ibm.com/purpose=operator-admission-shim \
    --overwrite
done

echo "==> Applying QueueManager manifests..."
oc apply -f "${SCRIPT_DIR}/qmgr-live.yaml"
oc apply -f "${SCRIPT_DIR}/qmgr-recovery.yaml"

echo ""
echo "==> Done. Secret '${SECRET_NAME}' contains only throwaway one-day shim material."
echo "    App PKI, NativeHA TLS, and NativeHA CRR TLS are injected by the init container from Vault."
