#!/usr/bin/env bash
# lib/status.sh - Show vault status, recent activity, and health overview
# Requires: VAULT_ROOT (set by dispatcher)

# Tiers to scan
readonly STATUS_TIERS=(active reference learning tooling archive)

# ---------------------------------------------------------------------------
# _date_to_epoch <YYYY-MM-DD>
#   Converts a date string to epoch seconds (portable across macOS/Linux).
# ---------------------------------------------------------------------------
_date_to_epoch() {
    local datestr="$1"
    if date -j -f '%Y-%m-%d' "$datestr" '+%s' 2>/dev/null; then
        return
    fi
    # Linux fallback
    date -d "$datestr" '+%s' 2>/dev/null
}

# ---------------------------------------------------------------------------
# _epoch_now
#   Returns current time as epoch seconds.
# ---------------------------------------------------------------------------
_epoch_now() {
    date '+%s'
}

# ---------------------------------------------------------------------------
# _today_str
#   Returns today's date as YYYY-MM-DD.
# ---------------------------------------------------------------------------
_today_str() {
    date '+%Y-%m-%d'
}

# ---------------------------------------------------------------------------
# _get_fm_field <field> <file>
#   Quick extraction of a frontmatter field from a file.
# ---------------------------------------------------------------------------
_get_fm_field() {
    local field="$1"
    local file="$2"
    local value

    # Read only the frontmatter portion (up to second ---)
    value="$(sed -n '2,/^---$/p' "$file" | sed -n "s/^${field}:[[:space:]]*//p" | head -n 1)"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# _parse_ttl <ttl_string>
#   Parses a TTL like "90d", "30d", "7d" and returns the number of days.
#   Returns empty string if unparseable.
# ---------------------------------------------------------------------------
_parse_ttl() {
    local ttl="$1"
    if [[ "$ttl" =~ ^([0-9]+)d$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# ---------------------------------------------------------------------------
# kb_status [--json]
#   Displays vault status including tier counts, recent updates, stale
#   entries, and overall health.
# ---------------------------------------------------------------------------
kb_status() {
    local json_mode=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_mode=1; shift ;;
            *) printf 'status: unknown option: %s\n' "$1" >&2; return 1 ;;
        esac
    done

    if [[ -z "${VAULT_ROOT:-}" ]]; then
        printf 'Error: VAULT_ROOT is not set\n' >&2
        return 1
    fi

    local now_epoch
    now_epoch="$(_epoch_now)"
    local seven_days_ago=$((now_epoch - 7 * 86400))

    # Collect per-tier counts
    declare -A tier_counts
    local total_count=0

    # Collect recent entries and stale entries
    local recent_entries=""
    local stale_count=0

    local tier
    for tier in "${STATUS_TIERS[@]}"; do
        local tier_dir="${VAULT_ROOT}/${tier}"
        local count=0

        if [[ ! -d "$tier_dir" ]]; then
            tier_counts["$tier"]=0
            continue
        fi

        while IFS= read -r -d '' file; do
            count=$((count + 1))
            total_count=$((total_count + 1))

            local entry_id
            entry_id="$(_get_fm_field "id" "$file")"
            local entry_title
            entry_title="$(_get_fm_field "title" "$file")"
            local updated
            updated="$(_get_fm_field "updated" "$file")"
            local ttl_str
            ttl_str="$(_get_fm_field "ttl" "$file")"

            # Check if recently updated (within 7 days)
            if [[ -n "$updated" ]]; then
                local updated_epoch
                updated_epoch="$(_date_to_epoch "$updated")"
                if [[ -n "$updated_epoch" ]] && [[ "$updated_epoch" -ge "$seven_days_ago" ]]; then
                    recent_entries="${recent_entries}${entry_id}|${entry_title}|${tier}|${updated}"$'\n'
                fi

                # Check staleness (skip archive tier)
                if [[ "$tier" != "archive" ]] && [[ -n "$ttl_str" ]]; then
                    local ttl_days
                    ttl_days="$(_parse_ttl "$ttl_str")"
                    if [[ -n "$ttl_days" ]] && [[ -n "$updated_epoch" ]]; then
                        local expiry_epoch=$((updated_epoch + ttl_days * 86400))
                        if [[ "$now_epoch" -gt "$expiry_epoch" ]]; then
                            stale_count=$((stale_count + 1))
                        fi
                    fi
                fi
            fi
        done < <(find "$tier_dir" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)

        tier_counts["$tier"]=$count
    done

    # Check INDEX.md freshness
    local index_status="unknown"
    local index_file="${VAULT_ROOT}/INDEX.md"
    if [[ -f "$index_file" ]]; then
        local index_mtime
        # macOS: stat -f '%m', Linux: stat -c '%Y'
        index_mtime="$(stat -f '%m' "$index_file" 2>/dev/null || stat -c '%Y' "$index_file" 2>/dev/null)"

        # Find newest entry mtime across all tiers
        local newest_entry_mtime=0
        for tier in "${STATUS_TIERS[@]}"; do
            local tier_dir="${VAULT_ROOT}/${tier}"
            [[ -d "$tier_dir" ]] || continue
            while IFS= read -r -d '' f; do
                local fmtime
                fmtime="$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null)"
                if [[ -n "$fmtime" ]] && [[ "$fmtime" -gt "$newest_entry_mtime" ]]; then
                    newest_entry_mtime="$fmtime"
                fi
            done < <(find "$tier_dir" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)
        done

        if [[ -n "$index_mtime" ]] && [[ "$newest_entry_mtime" -gt 0 ]]; then
            if [[ "$index_mtime" -ge "$newest_entry_mtime" ]]; then
                index_status="up-to-date"
            else
                index_status="stale"
            fi
        elif [[ -n "$index_mtime" ]]; then
            index_status="up-to-date"
        fi
    else
        index_status="missing"
    fi

    # Run a quick validation check (quiet mode) to count warnings
    local validation_warnings=0
    if [[ -f "${KB_ROOT:-}/lib/validate.sh" ]]; then
        local validate_output
        validate_output="$(source "${KB_ROOT}/lib/validate.sh" && kb_validate --quiet 2>/dev/null)" || true
        # Extract warning count from summary line
        if [[ "$validate_output" =~ ([0-9]+)\ warnings ]]; then
            validation_warnings="${BASH_REMATCH[1]}"
        fi
    fi

    # Determine overall health
    local health="HEALTHY"
    if [[ "$stale_count" -gt 0 ]] || [[ "$index_status" == "stale" ]] || [[ "$validation_warnings" -gt 0 ]]; then
        health="WARNINGS"
    fi
    if [[ "$index_status" == "missing" ]]; then
        health="ERRORS"
    fi

    # ------------------------------------------------------------------
    # Output: JSON mode
    # ------------------------------------------------------------------
    if [[ "$json_mode" -eq 1 ]]; then
        printf '{\n'
        printf '  "total_entries": %d,\n' "$total_count"
        printf '  "tiers": {\n'
        local first=1
        for tier in "${STATUS_TIERS[@]}"; do
            if [[ "$first" -eq 0 ]]; then printf ',\n'; fi
            printf '    "%s": %d' "$tier" "${tier_counts[$tier]}"
            first=0
        done
        printf '\n  },\n'
        printf '  "recent_count": %d,\n' "$(printf '%s' "$recent_entries" | grep -c . 2>/dev/null || printf '0')"
        printf '  "stale_count": %d,\n' "$stale_count"
        printf '  "index_status": "%s",\n' "$index_status"
        printf '  "validation_warnings": %d,\n' "$validation_warnings"
        printf '  "health": "%s"\n' "$health"
        printf '}\n'
        return 0
    fi

    # ------------------------------------------------------------------
    # Output: Terminal mode
    # ------------------------------------------------------------------
    printf '\n'
    printf '=== kb vault status ===\n\n'

    # Tier counts table
    printf '%-12s %s\n' "Tier" "Count"
    printf '%-12s %s\n' "----" "-----"
    for tier in "${STATUS_TIERS[@]}"; do
        printf '%-12s %d\n' "$tier" "${tier_counts[$tier]}"
    done
    printf '%-12s %s\n' "----" "-----"
    printf '%-12s %d\n\n' "TOTAL" "$total_count"

    # Recently updated
    printf '--- Recently Updated (last 7 days) ---\n'
    if [[ -n "$recent_entries" ]]; then
        printf '%-20s %-30s %-10s %s\n' "ID" "Title" "Tier" "Updated"
        printf '%-20s %-30s %-10s %s\n' "---" "-----" "----" "-------"
        while IFS='|' read -r rid rtitle rtier rupdated; do
            [[ -z "$rid" ]] && continue
            # Truncate title if too long
            if [[ "${#rtitle}" -gt 28 ]]; then
                rtitle="${rtitle:0:25}..."
            fi
            printf '%-20s %-30s %-10s %s\n' "$rid" "$rtitle" "$rtier" "$rupdated"
        done <<< "$recent_entries"
    else
        printf '  (none)\n'
    fi
    printf '\n'

    # Health summary
    printf '--- Vault Health ---\n'
    printf '  Stale entries:        %d\n' "$stale_count"
    printf '  INDEX.md:             %s\n' "$index_status"
    printf '  Validation warnings:  %d\n' "$validation_warnings"
    printf '  Overall:              %s\n\n' "$health"

    if [[ "$stale_count" -gt 0 ]]; then
        printf "  Tip: Run 'kb stale' to see overdue entries.\n"
    fi
    if [[ "$index_status" == "stale" ]]; then
        printf "  Tip: Run 'kb index' to rebuild INDEX.md.\n"
    fi
    printf '\n'
}

# Allow direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    kb_status "$@"
fi
