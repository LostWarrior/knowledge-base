#!/usr/bin/env bash
# lib/index.sh - Rebuild the INDEX.md and .kb/manifest.json from vault entries
# Requires: VAULT_ROOT

# Parse a single frontmatter field from a file
# Usage: _fm_field "field_name" "file_path"
_fm_field() {
    local field="$1"
    local file="$2"
    local value=""

    # Extract value between --- delimiters, find the field line
    value="$(sed -n '/^---$/,/^---$/{ /^'"$field"':/{ s/^'"$field"': *//; s/^"//; s/"$//; p; }; }' "$file")"
    printf '%s' "$value"
}

# Escape a string for safe JSON embedding (handle double quotes and backslashes)
_json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/}"
    str="${str//$'\t'/\\t}"
    printf '%s' "$str"
}

# Convert a comma-separated tags string (with optional brackets) to JSON array interior
# e.g. "foo, bar, baz" -> "\"foo\",\"bar\",\"baz\""
_manifest_tags() {
    local raw="$1"
    # Strip brackets if present
    raw="${raw#\[}"
    raw="${raw%\]}"
    if [[ -z "$raw" ]]; then
        printf ''
        return
    fi
    local result=""
    local IFS=','
    for tag in $raw; do
        # Trim whitespace
        tag="${tag#"${tag%%[![:space:]]*}"}"
        tag="${tag%"${tag##*[![:space:]]}"}"
        if [[ -n "$tag" ]]; then
            if [[ -n "$result" ]]; then
                result="$result,"
            fi
            result="$result\"$tag\""
        fi
    done
    printf '%s' "$result"
}

# Check if a file has valid frontmatter (starts with ---)
_has_frontmatter() {
    local file="$1"
    local first_line
    first_line="$(head -1 "$file")"
    [[ "$first_line" == "---" ]]
}

# Map tier directory name to expected status value
_tier_to_status() {
    local tier="$1"
    case "$tier" in
        active)    printf 'active' ;;
        archive)   printf 'archived' ;;
        reference) printf 'reference' ;;
        learning)  printf 'learning' ;;
        tooling)   printf 'tooling' ;;
        *)         printf '%s' "$tier" ;;
    esac
}

kb_index() {
    # Ensure VAULT_ROOT is set
    if [[ -z "${VAULT_ROOT:-}" ]]; then
        printf 'Error: VAULT_ROOT is not set - are you in a kb vault?\n' >&2
        return 1
    fi

    local index_file="$VAULT_ROOT/INDEX.md"
    local manifest_file="$VAULT_ROOT/.kb/manifest.json"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M')"

    # Tiers to scan - archive is included for manifest but handled separately for INDEX.md
    local scan_tiers=( "active" "reference" "learning" "tooling" )
    local all_tiers=( "active" "reference" "learning" "tooling" "archive" )
    local archive_count=0
    local total_count=0
    local warnings=0

    # Collect entries per tier into associative-like structures
    # We use temp files per tier to hold sorted table rows
    local tmpdir
    tmpdir="$(mktemp -d)"

    # Manifest entries temp file (one JSON object per line, prefixed with tier sort key)
    local manifest_tmp="$tmpdir/manifest_entries"
    : > "$manifest_tmp"

    # Count per tier for summary (avoid associative arrays for bash 3 compat)
    local count_active=0 count_reference=0 count_learning=0 count_tooling=0

    for tier in "${scan_tiers[@]}"; do
        local tier_dir="$VAULT_ROOT/$tier"

        if [[ ! -d "$tier_dir" ]]; then
            continue
        fi

        # Collect entries with their updated date for sorting
        local entries_file="$tmpdir/${tier}_entries"
        : > "$entries_file"

        for mdfile in "$tier_dir"/*.md; do
            # Skip if glob matched nothing
            [[ -f "$mdfile" ]] || continue

            if ! _has_frontmatter "$mdfile"; then
                printf 'Warning: missing frontmatter in %s\n' "$mdfile" >&2
                warnings=$((warnings + 1))
                continue
            fi

            local entry_id entry_title entry_domain entry_updated entry_tags entry_status entry_type entry_summary
            entry_id="$(_fm_field "id" "$mdfile")"
            entry_title="$(_fm_field "title" "$mdfile")"
            entry_domain="$(_fm_field "domain" "$mdfile")"
            entry_updated="$(_fm_field "updated" "$mdfile")"
            entry_tags="$(_fm_field "tags" "$mdfile")"
            entry_status="$(_fm_field "status" "$mdfile")"
            entry_type="$(_fm_field "type" "$mdfile")"
            entry_summary="$(_fm_field "summary" "$mdfile")"

            # Warn if status mismatches tier
            local expected_status
            expected_status="$(_tier_to_status "$tier")"
            if [[ -n "$entry_status" ]] && [[ "$entry_status" != "$expected_status" ]]; then
                printf 'Warning: %s has status "%s" but is in %s/ tier (expected "%s")\n' \
                    "$mdfile" "$entry_status" "$tier" "$expected_status" >&2
                warnings=$((warnings + 1))
            fi

            # Default to filename-based id if missing
            if [[ -z "$entry_id" ]]; then
                entry_id="$(basename "$mdfile" .md)"
            fi

            # Clean up tags display: strip brackets for table
            entry_tags="${entry_tags#\[}"
            entry_tags="${entry_tags%\]}"

            # Write sort key (updated date) + table row
            printf '%s\t| %s | %s | %s | %s | %s |\n' \
                "$entry_updated" \
                "$entry_id" "$entry_title" "$entry_domain" "$entry_updated" "$entry_tags" \
                >> "$entries_file"

            # Write manifest entry (tier sort key + JSON object)
            local rel_path
            rel_path="${tier}/$(basename "$mdfile")"
            local j_id j_title j_status j_type j_domain j_path j_updated j_tags j_summary
            j_id="$(_json_escape "$entry_id")"
            j_title="$(_json_escape "$entry_title")"
            j_status="$(_json_escape "$entry_status")"
            j_type="$(_json_escape "$entry_type")"
            j_domain="$(_json_escape "$entry_domain")"
            j_path="$(_json_escape "$rel_path")"
            j_updated="$(_json_escape "$entry_updated")"
            j_tags="$(_json_escape "$entry_tags")"
            j_summary="$(_json_escape "$entry_summary")"
            printf '%s\t{"id":"%s","title":"%s","status":"%s","type":"%s","domain":"%s","path":"%s","updated":"%s","tags":[%s],"summary":"%s"}\n' \
                "$tier" "$j_id" "$j_title" "$j_status" "$j_type" "$j_domain" "$j_path" "$j_updated" \
                "$(_manifest_tags "$j_tags")" "$j_summary" \
                >> "$manifest_tmp"

            eval "count_${tier}=$(( $(eval "echo \$count_${tier}") + 1 ))"
            total_count=$((total_count + 1))
        done
    done

    # Count archive entries and collect manifest data
    if [[ -d "$VAULT_ROOT/archive" ]]; then
        for mdfile in "$VAULT_ROOT/archive"/*.md; do
            [[ -f "$mdfile" ]] || continue

            if _has_frontmatter "$mdfile"; then
                local entry_id entry_title entry_domain entry_updated entry_tags entry_status entry_type entry_summary
                entry_id="$(_fm_field "id" "$mdfile")"
                entry_title="$(_fm_field "title" "$mdfile")"
                entry_domain="$(_fm_field "domain" "$mdfile")"
                entry_updated="$(_fm_field "updated" "$mdfile")"
                entry_tags="$(_fm_field "tags" "$mdfile")"
                entry_status="$(_fm_field "status" "$mdfile")"
                entry_type="$(_fm_field "type" "$mdfile")"
                entry_summary="$(_fm_field "summary" "$mdfile")"

                if [[ -z "$entry_id" ]]; then
                    entry_id="$(basename "$mdfile" .md)"
                fi

                # Strip brackets from tags for manifest
                entry_tags="${entry_tags#\[}"
                entry_tags="${entry_tags%\]}"

                local rel_path
                rel_path="archive/$(basename "$mdfile")"
                local j_id j_title j_status j_type j_domain j_path j_updated j_tags j_summary
                j_id="$(_json_escape "$entry_id")"
                j_title="$(_json_escape "$entry_title")"
                j_status="$(_json_escape "${entry_status:-archived}")"
                j_type="$(_json_escape "$entry_type")"
                j_domain="$(_json_escape "$entry_domain")"
                j_path="$(_json_escape "$rel_path")"
                j_updated="$(_json_escape "$entry_updated")"
                j_tags="$(_json_escape "$entry_tags")"
                j_summary="$(_json_escape "$entry_summary")"
                printf '%s\t{"id":"%s","title":"%s","status":"%s","type":"%s","domain":"%s","path":"%s","updated":"%s","tags":[%s],"summary":"%s"}\n' \
                    "archive" "$j_id" "$j_title" "$j_status" "$j_type" "$j_domain" "$j_path" "$j_updated" \
                    "$(_manifest_tags "$j_tags")" "$j_summary" \
                    >> "$manifest_tmp"
            fi

            archive_count=$((archive_count + 1))
            total_count=$((total_count + 1))
        done
    fi

    # Build INDEX.md
    {
        printf '# Knowledge Base Index\n\n'
        # shellcheck disable=SC2016
        printf '> Auto-generated on %s. Do not edit manually - run `kb index` to regenerate.\n\n' "$timestamp"

        for tier in "${scan_tiers[@]}"; do
            # Capitalize tier name for heading
            local heading
            heading="$(printf '%s' "$tier" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
            printf '## %s\n\n' "$heading"
            printf '| ID | Title | Domain | Updated | Tags |\n'
            printf '|----|-------|--------|---------|------|\n'

            local entries_file="$tmpdir/${tier}_entries"
            if [[ -s "$entries_file" ]]; then
                # Sort by date descending (newest first), then strip the sort key
                sort -t$'\t' -k1,1r "$entries_file" | cut -f2-
            fi

            printf '\n'
        done

        printf '## Archive\n\n'
        # shellcheck disable=SC2016
        printf '_%d archived entries. Use `kb search` to find archived content._\n' "$archive_count"
    } > "$index_file"

    # Build manifest.json sorted by tier order (active, reference, learning, tooling, archive)
    {
        printf '[\n'
        local first_entry=1
        for tier in "${all_tiers[@]}"; do
            while IFS=$'\t' read -r _sort_key json_obj; do
                if [[ "$first_entry" -eq 1 ]]; then
                    first_entry=0
                else
                    printf ',\n'
                fi
                printf '  %s' "$json_obj"
            done < <(grep "^${tier}	" "$manifest_tmp" 2>/dev/null || true)
        done
        printf '\n]\n'
    } > "$manifest_file"

    # Clean up
    rm -rf "$tmpdir"

    # Print summary
    local summary="Indexed $total_count entries"
    local parts=()
    for tier in "${scan_tiers[@]}"; do
        local count
        eval "count=\$count_${tier}"
        if [[ "$count" -gt 0 ]]; then
            parts+=("$count $tier")
        fi
    done
    if [[ "$archive_count" -gt 0 ]]; then
        parts+=("$archive_count archived")
    fi

    if [[ ${#parts[@]} -gt 0 ]]; then
        local IFS=', '
        summary="$summary (${parts[*]})"
    fi

    printf '%s\n' "$summary"
    printf 'Updated INDEX.md and .kb/manifest.json\n'

    if [[ "$warnings" -gt 0 ]]; then
        printf '%d warning(s) - check stderr for details\n' "$warnings" >&2
    fi
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    kb_index "$@"
fi
