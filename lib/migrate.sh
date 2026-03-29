#!/usr/bin/env bash
# lib/migrate.sh - Import a markdown directory into the kb vault
# Orchestrates: _migrate_utils.sh, _migrate_parse.sh, _migrate_scan.sh,
#               _migrate_preview.sh, _migrate_execute.sh
set -euo pipefail

# Source dependencies
# shellcheck source=/dev/null
source "${KB_ROOT}/lib/_theme.sh"
# shellcheck source=/dev/null
source "${KB_ROOT}/lib/_migrate_utils.sh"
# shellcheck source=/dev/null
source "${KB_ROOT}/lib/_migrate_parse.sh"
# shellcheck source=/dev/null
source "${KB_ROOT}/lib/_migrate_scan.sh"
# shellcheck source=/dev/null
source "${KB_ROOT}/lib/_migrate_preview.sh"
# shellcheck source=/dev/null
source "${KB_ROOT}/lib/_migrate_execute.sh"

kb_migrate() {
    local source_dir="" dry_run="false" yes_flag="false" no_compact="false"
    local -a excludes=()

    # --- Parse arguments ---
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)    dry_run="true"; shift ;;
            --yes)        yes_flag="true"; shift ;;
            --no-compact) no_compact="true"; shift ;;
            --exclude)    excludes+=("$2"); shift 2 ;;
            -*)           _err "Unknown flag: $1"; return 1 ;;
            *)
                if [[ -z "$source_dir" ]]; then
                    source_dir="$1"
                else
                    _err "Unexpected argument: $1"; return 1
                fi
                shift ;;
        esac
    done

    if [[ -z "$source_dir" ]]; then
        _err "Usage: kb migrate <source-dir> [--dry-run] [--yes] [--no-compact] [--exclude <glob>]"
        return 1
    fi

    # --- Validate ---
    _mig_validate_path "$source_dir" || return 1
    if [[ ! -d "$source_dir" ]]; then
        _err "Source directory not found: $source_dir"
        return 1
    fi
    if [[ -z "${VAULT_ROOT:-}" ]]; then
        _err "Not inside a kb vault. Run 'kb init' first."
        return 1
    fi
    # Prevent source being parent of vault
    local real_source real_vault
    real_source="$(cd "$source_dir" && pwd)"
    real_vault="$(cd "$VAULT_ROOT" && pwd)"
    if [[ "$real_vault" == "$real_source"* ]]; then
        _err "Source directory cannot be a parent of the vault"
        return 1
    fi

    # --- Phase 1: Scan ---
    local plan_file
    plan_file="$(mktemp)"
    trap 'rm -f -- "${plan_file:-}"' EXIT

    local counts
    counts="$(_mig_scan "$source_dir" "$VAULT_ROOT" "$plan_file" "$no_compact" "${excludes[@]+"${excludes[@]}"}")"

    # --- Phase 2: Preview ---
    _mig_preview "$source_dir" "$plan_file" "$counts"

    if ! _mig_confirm "$dry_run" "$yes_flag" "$VAULT_ROOT" "$plan_file"; then
        return 0
    fi

    # --- Phase 3: Execute ---
    _mig_execute "$source_dir" "$VAULT_ROOT" "$plan_file"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    kb_migrate "$@"
fi
