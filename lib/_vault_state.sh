#!/usr/bin/env bash
# lib/_vault_state.sh - Shared helpers for vault freshness and regeneration
# Requires: VAULT_ROOT, KB_ROOT

_kb_stat_mtime() {
    local file="$1"
    stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null
}

_kb_latest_entry_info() {
    local newest_mtime=0
    local newest_file=""
    local tier tier_dir file file_mtime
    local tiers=(active reference learning tooling archive)

    for tier in "${tiers[@]}"; do
        tier_dir="${VAULT_ROOT}/${tier}"
        [[ -d "$tier_dir" ]] || continue

        while IFS= read -r -d '' file; do
            file_mtime="$(_kb_stat_mtime "$file")"
            if [[ -n "$file_mtime" ]] && [[ "$file_mtime" -gt "$newest_mtime" ]]; then
                newest_mtime="$file_mtime"
                newest_file="${file#"${VAULT_ROOT}/"}"
            fi
        done < <(find "$tier_dir" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)
    done

    printf '%s\t%s' "$newest_mtime" "$newest_file"
}

kb_refresh_indexes() {
    if [[ -z "${KB_ROOT:-}" ]]; then
        printf 'Error: KB_ROOT is not set\n' >&2
        return 1
    fi

    if [[ -z "${VAULT_ROOT:-}" ]]; then
        printf 'Error: VAULT_ROOT is not set\n' >&2
        return 1
    fi

    # shellcheck source=/dev/null
    source "${KB_ROOT}/lib/index.sh"
    kb_index
}
