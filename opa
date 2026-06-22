#!/bin/bash

################################################################################
# hvault_final.sh
# 
# Creates EXACT output format:
# oracle_name=PATH/""PASSWORD""
# instance_name:INSTANCENAME
#
# NO placeholder replacement, just inject password with quotes
# NO empty lines between connections
################################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
SUCCESS_COUNT=0
FAIL_COUNT=0

# Configuration
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-AP11436}"
VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-false}"
MOUNT="cloud"
BASE_PATH="oracle/qua"
INPUT_FILE=""

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
Usage: $0 -i INPUT_FILE [OPTIONS]

Required Arguments:
  -i INPUT_FILE             Input file with connections and PLACEHOLDER

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

Input File Format:
  oracle_name=PATH/PLACEHOLDER
  instance_name:INSTANCENAME

Output Format:
  oracle_name=PATH/""PASSWORD""
  instance_name:INSTANCENAME

Example:
  ./hvault_final.sh -i static_connections.conf

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
    if [[ -z "$INPUT_FILE" ]]; then
        log_error "Input file (-i) is required"
        usage
    fi
    
    if [[ ! -f "$INPUT_FILE" ]]; then
        log_error "File not found: $INPUT_FILE"
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
    
    log_debug "Fetching password for instance: $instance"
    
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

# Extract instance name from "instance_name:INSTANCENAME"
extract_instance() {
    local line="$1"
    
    # Format: instance_XXX:INSTANCENAME
    # Extract everything after the colon
    echo "$line" | sed 's/.*://'
}

# Check if line is a connection line (contains oracle_ and /PLACEHOLDER)
is_connection_line() {
    local line="$1"
    
    [[ "$line" =~ ^oracle_ ]] && [[ "$line" =~ /PLACEHOLDER$ ]]
}

# Check if line is an instance line
is_instance_line() {
    local line="$1"
    
    [[ "$line" =~ ^instance_[^:]+:[A-Z0-9]+$ ]]
}

# Replace /PLACEHOLDER with /""PASSWORD""
inject_password() {
    local connection_line="$1"
    local password="$2"
    
    # Replace /PLACEHOLDER with /""PASSWORD""
    echo "$connection_line" | sed "s|/PLACEHOLDER|/\"\"${password}\"\"|"
}

################################################################################
# MAIN PROCESSING
################################################################################

process_file() {
    local file="$1"
    local line_num=0
    local pending_connection=""
    local in_comment_section=false
    
    log_info "Processing file: $file"
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        
        log_debug "Line $line_num: $line"
        
        # Handle comment/header lines - output as-is
        if [[ "$line" =~ ^# ]] || [[ "$line" =~ ^= ]]; then
            log_debug "Line $line_num: Comment/header"
            echo "$line"
            in_comment_section=true
            continue
        fi
        
        # Empty lines in comment sections - output as-is
        if [[ -z "$line" ]]; then
            log_debug "Line $line_num: Empty line"
            # Only output if in comment section
            if [[ "$in_comment_section" == "true" ]]; then
                echo "$line"
            fi
            continue
        fi
        
        in_comment_section=false
        
        # Check if this is a connection line
        if is_connection_line "$line"; then
            log_debug "Line $line_num: Connection line detected"
            pending_connection="$line"
            continue
        fi
        
        # Check if this is an instance line
        if is_instance_line "$line"; then
            log_debug "Line $line_num: Instance line detected"
            
            # We should have a pending connection
            if [[ -z "$pending_connection" ]]; then
                log_warn "Line $line_num: Instance line without connection line, skipping"
                echo "$line"
                continue
            fi
            
            # Extract instance name
            local instance
            instance=$(extract_instance "$line")
            log_debug "Extracted instance: $instance"
            
            # Fetch password
            local password
            if ! password=$(fetch_password_from_vault "$instance"); then
                log_error "Line $line_num: Failed to fetch password for $instance"
                # Output pending connection and instance as-is on error
                echo "$pending_connection"
                echo "$line"
                ((FAIL_COUNT++))
                pending_connection=""
                continue
            fi
            
            # Inject password into connection line
            local updated_connection
            updated_connection=$(inject_password "$pending_connection" "$password")
            
            log_success "Line $line_num: Password injected for instance $instance"
            
            # Output the pair (no empty line between them)
            echo "$updated_connection"
            echo "$line"
            
            ((SUCCESS_COUNT++))
            pending_connection=""
            continue
        fi
        
        # Any other line - output as-is
        log_debug "Line $line_num: Other line (metadata or comment)"
        echo "$line"
        
    done < "$file"
    
    # Print summary to stderr
    echo "" >&2
    log_info "Processing Complete:"
    log_success "  Successfully processed: $SUCCESS_COUNT connections"
    [[ $FAIL_COUNT -gt 0 ]] && log_error "  Failed: $FAIL_COUNT connections"
}

################################################################################
# MAIN
################################################################################

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i)
                INPUT_FILE="$2"
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
    log_info "║  hvault_final.sh - Password Injector              ║"
    log_info "╚════════════════════════════════════════════════════╝"
    
    process_file "$INPUT_FILE"
    
    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
    
    exit 0
}

main "$@"
