#!/usr/bin/env bash
# lib/stale.sh - Find entries past their TTL expiry date
# Requires: VAULT_ROOT (set by dispatcher)

# Tiers to check (archive is excluded - those are already retired)
readonly STALE_TIERS=(active reference learning tooling)

# ---------------------------------------------------------------------------
# _stale_date_to_epoch <YYYY-MM-DD>
#   Converts a date string to epoch seconds (portable macOS/Linux).
# ---------------------------------------------------------------------------
_stale_date_to_epoch() {
    local datestr="$1"
    if date -j -f '%Y-%m-%d' "$datestr" '+%s' 2>/dev/null; then
        return
    fi
    date -d "$datestr" '+%s' 2>/dev/null
}

# ---------------------------------------------------------------------------
# _stale_epoch_now
#   Returns current time as epoch seconds.
# ---------------------------------------------------------------------------
_stale_epoch_now() {
    date '+%s'
}

# ---------------------------------------------------------------------------
# _stale_get_fm_field <field> <file>
#   Extracts a frontmatter field value from a file.
# ---------------------------------------------------------------------------
_stale_get_fm_field() {
    local field="$1"
    local file="$2"
    local value

    value="$(sed -n '2,/^---$/p' "$file" | sed -n "s/^${field}:[[:space:]]*//p" | head -n 1)"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# _stale_parse_ttl <ttl_string>
#   Parses a TTL value like "90d" and returns days as integer.
#   Returns empty string if format is unrecognized.
# ---------------------------------------------------------------------------
_stale_parse_ttl() {
    local ttl="$1"
    if [[ "$ttl" =~ ^([0-9]+)d$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# ---------------------------------------------------------------------------
# kb_stale [--days N]
#   Scans non-archive tiers and reports entries past their TTL.
#   --days N: override per-entry TTL with a fixed number of days
# ---------------------------------------------------------------------------
kb_stale() {
    if [[ -z "${VAULT_ROOT:-}" ]]; then
        printf 'Error: VAULT_ROOT is not set\n' >&2
        return 1
    fi

    local override_days=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)
                if [[ $# -lt 2 ]]; then
                    printf 'Error: --days requires a numeric value\n' >&2
                    return 1
                fi
                # Validate numeric input
                if [[ ! "$2" =~ ^[0-9]+$ ]]; then
                    printf 'Error: --days value must be a positive integer\n' >&2
                    return 1
                fi
                override_days="$2"
                shift 2
                ;;
            *)
                printf 'stale: unknown option: %s\n' "$1" >&2
                return 1
                ;;
        esac
    done

    local now_epoch
    now_epoch="$(_stale_epoch_now)"

    # Collect stale entries: id|title|tier|updated|ttl|days_overdue
    local stale_entries=""
    local stale_count=0
    local scanned_count=0
    local skipped_count=0

    local tier
    for tier in "${STALE_TIERS[@]}"; do
        local tier_dir="${VAULT_ROOT}/${tier}"
        [[ -d "$tier_dir" ]] || continue

        while IFS= read -r -d '' file; do
            scanned_count=$((scanned_count + 1))

            local entry_id
            entry_id="$(_stale_get_fm_field "id" "$file")"
            local entry_title
            entry_title="$(_stale_get_fm_field "title" "$file")"
            local updated
            updated="$(_stale_get_fm_field "updated" "$file")"

            # Must have an updated date to check staleness
            if [[ -z "$updated" ]]; then
                skipped_count=$((skipped_count + 1))
                continue
            fi

            local updated_epoch
            updated_epoch="$(_stale_date_to_epoch "$updated")"
            if [[ -z "$updated_epoch" ]]; then
                skipped_count=$((skipped_count + 1))
                continue
            fi

            # Determine TTL days to use
            local ttl_days=""
            local ttl_display=""

            if [[ -n "$override_days" ]]; then
                ttl_days="$override_days"
                ttl_display="${override_days}d (override)"
            else
                local ttl_str
                ttl_str="$(_stale_get_fm_field "ttl" "$file")"
                if [[ -z "$ttl_str" ]]; then
                    skipped_count=$((skipped_count + 1))
                    continue
                fi
                ttl_days="$(_stale_parse_ttl "$ttl_str")"
                if [[ -z "$ttl_days" ]]; then
                    skipped_count=$((skipped_count + 1))
                    continue
                fi
                ttl_display="$ttl_str"
            fi

            # Calculate expiry
            local expiry_epoch=$((updated_epoch + ttl_days * 86400))
            if [[ "$now_epoch" -gt "$expiry_epoch" ]]; then
                local days_overdue=$(( (now_epoch - expiry_epoch) / 86400 ))
                stale_entries="${stale_entries}${entry_id}|${entry_title}|${tier}|${updated}|${ttl_display}|${days_overdue}"$'\n'
                stale_count=$((stale_count + 1))
            fi
        done < <(find "$tier_dir" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)
    done

    # ------------------------------------------------------------------
    # Output
    # ------------------------------------------------------------------
    printf '\n--- kb stale check ---\n\n'
    printf 'Scanned: %d entries (%d skipped - no TTL or date)\n\n' "$scanned_count" "$skipped_count"

    if [[ "$stale_count" -eq 0 ]]; then
        printf 'No stale entries found. All entries are within their TTL.\n\n'
        return 0
    fi

    printf 'Found %d stale entry/entries:\n\n' "$stale_count"

    # Table header
    printf '%-20s %-25s %-10s %-12s %-8s %s\n' \
        "ID" "Title" "Tier" "Updated" "TTL" "Overdue"
    printf '%-20s %-25s %-10s %-12s %-8s %s\n' \
        "---" "-----" "----" "-------" "---" "-------"

    # Sort by days overdue (descending) for visibility
    local sorted
    sorted="$(printf '%s' "$stale_entries" | sort -t'|' -k6 -rn)"

    while IFS='|' read -r sid stitle stier supdated sttl soverdue; do
        [[ -z "$sid" ]] && continue

        # Truncate title if too long
        if [[ "${#stitle}" -gt 23 ]]; then
            stitle="${stitle:0:20}..."
        fi

        printf '%-20s %-25s %-10s %-12s %-8s %s days\n' \
            "$sid" "$stitle" "$stier" "$supdated" "$sttl" "$soverdue"
    done <<< "$sorted"

    printf '\n'
    printf "Action: Run 'kb move <id> archive' to archive stale entries.\n"
    printf "        Run 'kb edit <id>' to update and reset the TTL.\n\n"

    return 0
}

# Allow direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    kb_stale "$@"
fi
