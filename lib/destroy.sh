#!/usr/bin/env bash
# lib/destroy.sh - Delete an entire kb vault
set -euo pipefail

# shellcheck source=/dev/null
source "${KB_ROOT}/lib/_theme.sh"

_destroy_usage() {
    printf 'Usage: kb destroy [<vault-dir>] [--yes]\n' >&2
}

_destroy_is_vault() {
    local dir="$1"
    [[ -d "${dir}/.kb" ]] && [[ -f "${dir}/.kb/kb.yaml" ]]
}

_destroy_count_entries() {
    local dir="$1"
    find \
        "${dir}/active" \
        "${dir}/reference" \
        "${dir}/learning" \
        "${dir}/tooling" \
        "${dir}/archive" \
        -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '
}

kb_destroy() {
    local target_arg=""
    local yes_flag="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes)
                yes_flag="true"
                shift
                ;;
            -*)
                _err "Unknown flag: $1"
                _destroy_usage
                return 1
                ;;
            *)
                if [[ -z "$target_arg" ]]; then
                    target_arg="$1"
                else
                    _err "Unexpected argument: $1"
                    _destroy_usage
                    return 1
                fi
                shift
                ;;
        esac
    done

    local vault_root=""
    if [[ -n "$target_arg" ]]; then
        if [[ ! -d "$target_arg" ]]; then
            _err "Vault directory not found: $target_arg"
            return 1
        fi
        vault_root="$(cd "$target_arg" && pwd -P)"
    elif [[ -n "${VAULT_ROOT:-}" ]]; then
        vault_root="$(cd "${VAULT_ROOT}" && pwd -P)"
    else
        _err "Not inside a kb vault. Provide a vault path or run from inside one."
        _destroy_usage
        return 1
    fi

    if ! _destroy_is_vault "$vault_root"; then
        _err "Not a kb vault: $vault_root"
        return 1
    fi

    if [[ "$vault_root" == "/" ]]; then
        _err "Refusing to delete the filesystem root"
        return 1
    fi

    local current_dir vault_name entry_count
    current_dir="$(pwd -P)"
    vault_name="$(basename "$vault_root")"
    entry_count="$(_destroy_count_entries "$vault_root")"

    _warn "This will permanently delete the entire vault directory."
    _detail "Vault: ${vault_root}"
    _detail "Markdown entries: ${entry_count}"

    if [[ "$current_dir" == "$vault_root" || "$current_dir" == "$vault_root/"* ]]; then
        _warn "Your shell is currently inside this vault."
        _detail "After deletion, run 'cd ..' or 'cd ~' in your shell."
    fi

    if [[ "$yes_flag" != "true" ]]; then
        printf '%s>>%s  Type %s to confirm deletion: ' "$_c_cyan" "$_c_reset" "$vault_name"
        local answer
        if ! read -r answer < /dev/tty; then
            _skip "Deletion cancelled."
            return 0
        fi
        if [[ "$answer" != "$vault_name" ]]; then
            _skip "Deletion cancelled."
            return 0
        fi
    fi

    rm -rf -- "$vault_root"
    _ok "Deleted vault: ${vault_root}"

    if [[ "$current_dir" == "$vault_root" || "$current_dir" == "$vault_root/"* ]]; then
        _warn "Your shell may still be attached to a deleted directory."
        _detail "Run 'cd ..' or 'cd ~' next."
    fi
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    kb_destroy "$@"
fi
