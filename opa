#!/bin/bash

################################################################################
# hvault.sh - FINAL VERSION
# Output format matches EXISTING .prm file structure
#
# Format:
#   oracle=SERVICE/'"password"''
#   instance:INSTANCE_ID
#
################################################################################

set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"
VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-false}"

MOUNT="cloud"
BASE_PATH="oracle/qua"
CONF_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config) shift; CONF_FILE="$1" ;;
        -b|--base-path) shift; BASE_PATH="$1" ;;
        -h|--help)
            cat <<'EOF'
hvault.sh - Vault Oracle Credentials

Usage: ./hvault.sh -c CONFIG_FILE [-b BASE_PATH]

Options:
  -c CONFIG_FILE      Config file (required)
  -b BASE_PATH        Base path (default: oracle/qua)

Environment Variables (REQUIRED):
  VAULT_ADDR          Vault URL
  VAULT_TOKEN         Vault token
  VAULT_NAMESPACE     Vault namespace

EOF
            exit 0
            ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# Validation
[ -z "$VAULT_ADDR" ] && echo "[ERROR] VAULT_ADDR not set" >&2 && exit 1
[ -z "$VAULT_TOKEN" ] && echo "[ERROR] VAULT_TOKEN not set" >&2 && exit 1
[ -z "$VAULT_NAMESPACE" ] && echo "[ERROR] VAULT_NAMESPACE not set" >&2 && exit 1
[ -z "$CONF_FILE" ] && echo "[ERROR] Config file (-c) required" >&2 && exit 1
[ ! -f "$CONF_FILE" ] && echo "[ERROR] Config file not found: $CONF_FILE" >&2 && exit 1

# ============================================================================
# MAIN PROCESSING
# ============================================================================

success_count=0
error_count=0

while IFS= read -r line; do
    # Skip empty lines and comments
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    
    # Trim whitespace
    line=$(echo "$line" | xargs)
    
    # Parse ENV/INSTANCE format
    if [[ ! "$line" =~ / ]]; then
        echo "[ERROR] Invalid format: $line" >&2
        ((error_count++))
        continue
    fi
    
    IFS='/' read -r env instance <<< "$line"
    
    if [[ -z "$env" ]] || [[ -z "$instance" ]]; then
        ((error_count++))
        continue
    fi
    
    # Build Vault path
    key="${BASE_PATH}/${env}/${instance}"
    data_url="${VAULT_ADDR}/v1/${VAULT_NAMESPACE}/${MOUNT}/data/${key}"
    
    # Fetch from Vault
    curl_opts=(-sS --fail)
    [ "$VAULT_SKIP_VERIFY" = true ] && curl_opts+=(-k)
    
    if resp=$(curl "${curl_opts[@]}" \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "$data_url" 2>&1); then
        
        # Extract secret data
        secret_data=$(echo "$resp" | jq '.data.data' 2>/dev/null)
        
        if [ -z "$secret_data" ] || [ "$secret_data" = "null" ]; then
            echo "[ERROR] No data for $instance" >&2
            ((error_count++))
            continue
        fi
        
        # Extract fields
        username=$(echo "$secret_data" | jq -r '.username // "UNKNOWN"')
        password=$(echo "$secret_data" | jq -r '.password // "UNKNOWN"')
        pdb=$(echo "$secret_data" | jq -r '.pdb // "UNKNOWN"')
        service=$(echo "$secret_data" | jq -r '.service // "UNKNOWN"')
        instance_id=$(echo "$secret_data" | jq -r '.pdb // "UNKNOWN"' | sed 's/WAREHOUSE/Q11436/')
        
        var_name="${instance}"
        
        ((success_count++))
        
        # OUTPUT IN YOUR EXISTING .prm FORMAT:
        # oracle=SERVICE/'"password"''
        # instance:INSTANCE_ID
        echo "oracle=${pdb}/'\"\${password}\"''"
        echo "instance:${pdb}P10"
        echo ""
        
    else
        echo "[ERROR] Failed to fetch $instance" >&2
        ((error_count++))
    fi
    
done < "$CONF_FILE"

[ $error_count -gt 0 ] && exit 1
exit 0
