#!/bin/bash

################################################################################
# hvault_v3.sh - Smart Block Processor
#
# Preserves EXACT file structure:
#   #comment
#   oracle_name=path/PLACEHOLDER
#   instance_name:INSTANCENAME
#   (empty line)
#
# Process:
# 1. Read instance mapping line
# 2. Extract instance name
# 3. Fetch password from Vault
# 4. Inject password into connection line
# 5. Output entire block (all 3-4 lines) with password injected
# 6. Move to next block
################################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
BLOCKS_PROCESSED=0
BLOCKS_FAILED=0

# Configuration
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-AP11436}"
VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-false}"
MOUNT="cloud"
BASE_PATH="oracle/qua"
STATIC_CONN_FILE=""

# Debug mode
DEBUG="${DEBUG:-false}"

################################################################################
# LOGGING
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[✗]${NC} $1" >&2
}

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

usage() {
    cat <<EOF
Usage: $0 -s STATIC_CONN_FILE [OPTIONS]

Required Arguments:
  -s STATIC_CONN_FILE       Static connections file with PLACEHOLDER

Optional Arguments:
  -m MOUNT_POINT            Vault mount point (default: cloud)
  -b BASE_PATH              Vault base path (default: oracle/qua)
  -h, --help                Show this help message

Environment Variables:
  VAULT_ADDR                Vault server address (required)
  VAULT_TOKEN               Vault authentication token (required)
  VAULT_NAMESPACE           Vault namespace (default: AP11436)
  VAULT_SKIP_VERIFY         Skip SSL verification (default: false)
  DEBUG                     Enable debug mode (default: false)

File Format:
  #connection_label
  oracle_logicalname=path/PLACEHOLDER
  instance_logicalname:INSTANCENAME
  (empty line)

Example:
  ./hvault_v3.sh -s static_connections.conf > output.conf

EOF
    exit 1
}

################################################################################
# VALIDATION
################################################################################

validate_environment() {
    if [[ -z "$VAULT_ADDR" ]]; then
        log_error "VAULT_ADDR environment variable not set"
        exit 1
    fi
    
    if [[ -z "$VAULT_TOKEN" ]]; then
        log_error "VAULT_TOKEN environment variable not set"
        exit 1
    fi
}

validate_files() {
    if [[ -z "$STATIC_CONN_FILE" ]]; then
        log_error "Static connections file (-s) is required"
        usage
    fi
    
    if [[ ! -f "$STATIC_CONN_FILE" ]]; then
        log_error "File not found: $STATIC_CONN_FILE"
        exit 1
    fi
}

################################################################################
# VAULT OPERATIONS
################################################################################

fetch_password_from_vault() {
    local instance="$1"
    
    # Extract environment from instance (last 2 chars)
    local env="${instance: -2}"
    local key_path="${BASE_PATH}/${env}/${instance}"
    
    log_debug "Fetching password for instance: $instance (path: $key_path)"
    
    local curl_opts=(-s -S)
    [[ "$VAULT_SKIP_VERIFY" == "true" ]] && curl_opts+=(-k)
    
    local response
    response=$(curl "${curl_opts[@]}" \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
        "${VAULT_ADDR}/v1/${VAULT_NAMESPACE}/${MOUNT}/data/${key_path}" 2>&1) || {
        log_error "Failed to reach Vault for $instance"
        return 1
    }
    
    local password
    password=$(echo "$response" | jq -r '.data.data.password // empty' 2>/dev/null) || {
        log_error "Failed to parse Vault response for $instance"
        return 1
    }
    
    [[ -z "$password" ]] && {
        log_error "No password found in Vault for instance: $instance"
        return 1
    }
    
    echo "$password"
    return 0
}

################################################################################
# EXTRACTION FUNCTIONS
################################################################################

# Extract instance name from line like "instance_warehouse_gbr:Q143652DP10"
extract_instance_from_mapping_line() {
    local line="$1"
    
    # Format: instance_LOGICALNAME:INSTANCENAME
    # Extract everything after the colon
    local instance
    instance=$(echo "$line" | sed 's/.*://')
    
    [[ -z "$instance" ]] && return 1
    echo "$instance"
}

# Extract logical name from line like "instance_warehouse_gbr:Q143652DP10"
extract_logical_name() {
    local line="$1"
    
    # Format: instance_LOGICALNAME:INSTANCENAME
    # Extract everything between "instance_" and ":"
    local logical
    logical=$(echo "$line" | sed 's/instance_//;s/:.*//')
    
    [[ -z "$logical" ]] && return 1
    echo "$logical"
}

# Replace PLACEHOLDER in connection line with actual password
replace_placeholder_with_password() {
    local connection_line="$1"
    local password="$2"
    
    # Escape special chars in password for sed
    local escaped_password
    escaped_password=$(printf '%s\n' "$password" | sed -e 's/[\/&]/\\&/g')
    
    # Replace /PLACEHOLDER with /PASSWORD
    echo "$connection_line" | sed "s|/PLACEHOLDER|/$escaped_password|g"
}

################################################################################
# MAIN PROCESSING
################################################################################

process_file() {
    local file="$1"
    local line_num=0
    local current_block=""
    local block_lines=0
    local connection_line=""
    local instance_line=""
    
    log_info "Processing file: $file"
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        
        # Accumulate lines into block
        if [[ -z "$line" ]]; then
            # Empty line = end of block
            if [[ -n "$connection_line" ]] && [[ -n "$instance_line" ]]; then
                # Process the complete block
                log_debug "Block complete at line $line_num"
                
                if process_block "$connection_line" "$instance_line"; then
                    # Output entire block (will be done in process_block)
                    true
                else
                    log_warn "Block processing failed at line $line_num"
                fi
            fi
            
            # Output the empty line
            echo ""
            
            # Reset block variables
            connection_line=""
            instance_line=""
            block_lines=0
        else
            # Non-empty line - add to block
            
            # Check if this is an instance mapping line
            if [[ "$line" =~ ^instance_[^:]+:[^:]+$ ]]; then
                log_debug "Line $line_num: Instance mapping line detected"
                instance_line="$line"
            elif [[ "$line" =~ ^oracle_[^=]+=.*/PLACEHOLDER$ ]]; then
                log_debug "Line $line_num: Connection line detected"
                connection_line="$line"
            else
                # Comment or other line - just output as-is
                log_debug "Line $line_num: Comment/metadata line"
                echo "$line"
            fi
        fi
        
    done < "$file"
    
    # Handle last block if file doesn't end with empty line
    if [[ -n "$connection_line" ]] && [[ -n "$instance_line" ]]; then
        log_debug "Processing final block"
        if process_block "$connection_line" "$instance_line"; then
            true
        else
            log_warn "Final block processing failed"
        fi
    fi
    
    # Print summary
    echo "" >&2
    log_info "Processing Complete:"
    log_success "  Blocks processed: $BLOCKS_PROCESSED"
    [[ $BLOCKS_FAILED -gt 0 ]] && log_error "  Blocks failed: $BLOCKS_FAILED"
}

# Process a single block (connection line + instance line)
process_block() {
    local connection_line="$1"
    local instance_line="$2"
    
    log_debug "=== Processing Block ==="
    log_debug "Connection: $connection_line"
    log_debug "Instance:   $instance_line"
    
    # Extract instance name
    local instance
    if ! instance=$(extract_instance_from_mapping_line "$instance_line"); then
        log_error "Failed to extract instance from: $instance_line"
        ((BLOCKS_FAILED++))
        
        # Output original lines as-is on error
        echo "$connection_line"
        echo "$instance_line"
        return 1
    fi
    
    # Extract logical name for logging
    local logical_name
    logical_name=$(extract_logical_name "$instance_line") || logical_name="unknown"
    
    log_info "Block: $logical_name → $instance"
    
    # Fetch password from Vault
    local password
    if ! password=$(fetch_password_from_vault "$instance"); then
        log_error "Failed to fetch password for $instance"
        ((BLOCKS_FAILED++))
        
        # Output original lines on error
        echo "# [ERROR] Failed to fetch password for $instance"
        echo "$connection_line"
        echo "$instance_line"
        return 1
    fi
    
    # Replace PLACEHOLDER with password
    local updated_connection
    updated_connection=$(replace_placeholder_with_password "$connection_line" "$password")
    
    log_success "Password injected for: $logical_name"
    log_debug "Updated: $updated_connection"
    
    # Output the updated block
    echo "$updated_connection"
    echo "$instance_line"
    
    ((BLOCKS_PROCESSED++))
    return 0
}

################################################################################
# MAIN
################################################################################

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s)
                STATIC_CONN_FILE="$2"
                shift 2
                ;;
            -m)
                MOUNT="$2"
                shift 2
                ;;
            -b)
                BASE_PATH="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    validate_environment
    validate_files
    
    log_info "╔════════════════════════════════════════════════════╗"
    log_info "║  hvault_v3.sh - Block-Based Password Injector     ║"
    log_info "╚════════════════════════════════════════════════════╝"
    
    process_file "$STATIC_CONN_FILE"
    
    if [[ $BLOCKS_FAILED -gt 0 ]]; then
        exit 1
    fi
    
    exit 0
}

main "$@"
