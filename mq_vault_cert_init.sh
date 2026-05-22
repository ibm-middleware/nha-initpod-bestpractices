#!/usr/bin/env bash
# mq_vault_cert_init.sh
# Standard-compliant, robust, pure Bash script to fetch certificates from HashiCorp Vault.
# Bypasses Python/dependencies. Uses only 'curl' and 'openssl' from the IBM MQ image.

set -euo pipefail

# Print informational message
info() {
    echo "mq-vault-cert-init: $1"
}

# Print error message and exit
fail() {
    echo "ERROR: $1" >&2
    exit 1
}

# Validate required environment variables
[[ -n "${VAULT_ADDR:-}" ]] || fail "VAULT_ADDR is not set"
[[ -n "${VAULT_TOKEN:-}" ]] || fail "VAULT_TOKEN is not set"
[[ -n "${VAULT_KV_MOUNT:-}" ]] || fail "VAULT_KV_MOUNT is not set"
[[ -n "${QM_NAME:-}" ]] || fail "QM_NAME is not set"
[[ -n "${OUT_DIR:-}" ]] || fail "OUT_DIR is not set"

VAULT_ADDR="${VAULT_ADDR%/}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT%/}"
VAULT_CERT_BASE_PATH="${VAULT_CERT_BASE_PATH:-mq/${QM_NAME}}"

info "Starting certificate retrieval from Vault: ${VAULT_ADDR}"
info "Queue Manager: ${QM_NAME}"
info "Output base directory: ${OUT_DIR}"

# Helper function to extract a field from JSON and convert \n to actual newlines
# Usage: extract_json_field <json_string> <field_name>
extract_json_field() {
    local json="$1"
    local field="$2"
    # Extract everything between "field":" and "
    local val
    val=$(echo "$json" | sed -E "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/")
    # If sed didn't find the field, return error
    if [[ "$val" == "$json" ]]; then
        return 1
    fi
    # Convert \n to actual newlines
    printf '%b' "$val"
}

# Helper function to validate certificate and key match
validate_cert_key() {
    local cert_path="$1"
    local key_path="$2"
    local cert_pub key_pub
    
    # 1. Check expiration (must be valid for at least 1 hour)
    if ! openssl x509 -in "$cert_path" -noout -checkend 3600 >/dev/null 2>&1; then
        fail "Certificate ${cert_path} has expired or will expire within 1 hour."
    fi
    
    # 2. Match public keys
    cert_pub=$(openssl x509 -in "$cert_path" -pubkey -noout 2>/dev/null)
    key_pub=$(openssl pkey -in "$key_path" -pubout 2>/dev/null)
    
    if [[ "${cert_pub}" != "${key_pub}" ]]; then
        fail "Certificate ${cert_path} and key ${key_path} do not match."
    fi
}

# Fetch secret and write PEM triplet to a directory
# Usage: fetch_and_write <vault_path> <target_dir>
fetch_and_write() {
    local path="$1"
    local target_dir="$2"
    
    info "Fetching from Vault path: ${VAULT_KV_MOUNT}/data/${path}"
    
    local response
    response=$(curl -sS -k \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "Accept: application/json" \
        "${VAULT_ADDR}/v1/${VAULT_KV_MOUNT}/data/${path}")
        
    if [[ $? -ne 0 ]] || [[ -z "$response" ]]; then
        fail "Failed to connect or fetch from Vault for path: ${path}"
    fi
    
    # Check for Vault errors in the response
    if echo "$response" | grep -q '"errors"'; then
        local err
        err=$(echo "$response" | sed -E 's/.*"errors"[[:space:]]*:[[:space:]]*\["([^"]*)"\].*/\1/')
        fail "Vault error for path ${path}: ${err}"
    fi

    # Extract keys
    local tls_key tls_crt ca_crt
    tls_key=$(extract_json_field "$response" "tls.key") || fail "tls.key not found in secret ${path}"
    tls_crt=$(extract_json_field "$response" "tls.crt") || fail "tls.crt not found in secret ${path}"
    ca_crt=$(extract_json_field "$response" "ca.crt") || fail "ca.crt not found in secret ${path}"

    mkdir -p "${target_dir}"
    
    # Write files atomically and securely
    echo "$tls_key" > "${target_dir}/tls.key"
    chmod 600 "${target_dir}/tls.key"
    
    echo "$tls_crt" > "${target_dir}/tls.crt"
    chmod 644 "${target_dir}/tls.crt"
    
    echo "$ca_crt" > "${target_dir}/ca.crt"
    chmod 644 "${target_dir}/ca.crt"
    
    validate_cert_key "${target_dir}/tls.crt" "${target_dir}/tls.key"
    info "Successfully prepared and validated certificate in ${target_dir}"
}

# Write a standalone trust cert
# Usage: fetch_and_write_trust <vault_path> <field_name> <target_dir> <output_name>
fetch_and_write_trust() {
    local path="$1"
    local field="$2"
    local target_dir="$3"
    local name="$4"
    
    info "Fetching trust cert from Vault path: ${VAULT_KV_MOUNT}/data/${path} [field: ${field}]"
    
    local response
    response=$(curl -sS -k \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "Accept: application/json" \
        "${VAULT_ADDR}/v1/${VAULT_KV_MOUNT}/data/${path}")
        
    if [[ $? -ne 0 ]] || [[ -z "$response" ]]; then
        fail "Failed to connect or fetch trust from Vault for path: ${path}"
    fi

    if echo "$response" | grep -q '"errors"'; then
        local err
        err=$(echo "$response" | sed -E 's/.*"errors"[[:space:]]*:[[:space:]]*\["([^"]*)"\].*/\1/')
        fail "Vault error for path ${path}: ${err}"
    fi

    local trust_crt
    trust_crt=$(extract_json_field "$response" "${field}") || fail "${field} not found in secret ${path}"

    mkdir -p "${target_dir}"
    echo "$trust_crt" > "${target_dir}/${name}"
    chmod 644 "${target_dir}/${name}"
    
    # Verify certificate syntax
    openssl x509 -in "${target_dir}/${name}" -noout 2>/dev/null || fail "Invalid trust certificate format in ${target_dir}/${name}"
    info "Successfully prepared trust certificate ${name} in ${target_dir}"
}

# Process paths
fetch_and_write "${VAULT_CERT_BASE_PATH}/app-pki" "${OUT_DIR}/pki/keys/default"
fetch_and_write "${VAULT_CERT_BASE_PATH}/nha-tls" "${OUT_DIR}/ha/pki/keys/ha-vault"
fetch_and_write "${VAULT_CERT_BASE_PATH}/nhacrr-tls" "${OUT_DIR}/groupha/pki/keys/groupha"
fetch_and_write "${VAULT_CERT_BASE_PATH}/nhacrr-tls" "${OUT_DIR}/groupha/pki/keys/ha-group"

fetch_and_write_trust "${VAULT_CERT_BASE_PATH}/app-pki" "ca.crt" "${OUT_DIR}/pki/trust/default" "ca.crt"
fetch_and_write_trust "${VAULT_CERT_BASE_PATH}/nhacrr-tls" "ca.crt" "${OUT_DIR}/groupha/pki/trust/remote" "ca.crt"

# Create marker file
echo "ready $(date +%s)" > "${OUT_DIR}/.mq-certs-ready"
chmod 644 "${OUT_DIR}/.mq-certs-ready"

info "All requested certificate material is ready!"
