#!/usr/bin/env bash
# lib/search.sh - Search vault entries across frontmatter and content
# Requires: VAULT_ROOT (set by dispatcher)

# Tiers to search by default (archive excluded unless --archive)
readonly SEARCH_DEFAULT_TIERS=(active reference learning tooling)

# ---------------------------------------------------------------------------
# _search_get_fm_field <field> <file>
#   Extracts a single frontmatter field value from a file.
# ---------------------------------------------------------------------------
_search_get_fm_field() {
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
# _search_get_tags <file>
#   Extracts the tags list from frontmatter. Returns comma-separated tags.
# ---------------------------------------------------------------------------
_search_get_tags() {
    local file="$1"
    local raw

    raw="$(sed -n '2,/^---$/p' "$file" | sed -n 's/^tags:[[:space:]]*//p' | head -n 1)"
    # Strip brackets and clean up
    raw="${raw#\[}"
    raw="${raw%\]}"
    # Remove quotes and extra spaces
    printf '%s' "$raw" | sed 's/"//g;s/'\''//g;s/[[:space:]]*,[[:space:]]*/,/g;s/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# _search_has_tag <needle_tag> <file>
#   Returns 0 if the file's tags contain the specified tag, 1 otherwise.
# ---------------------------------------------------------------------------
_search_has_tag() {
    local needle="$1"
    local file="$2"
    local tags
    tags="$(_search_get_tags "$file")"

    local IFS=','
    local tag
    for tag in $tags; do
        tag="$(printf '%s' "$tag" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [[ "$tag" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# _search_match_context <query> <file>
#   Returns a short snippet of the matching line for context display.
#   Limits to first match, truncated to 50 chars.
# ---------------------------------------------------------------------------
_search_match_context() {
    local query="$1"
    local file="$2"
    local match_line

    match_line="$(grep -i -m 1 "$query" "$file" 2>/dev/null || true)"
    if [[ -z "$match_line" ]]; then
        printf '(frontmatter match)'
        return
    fi

    # Trim leading whitespace
    match_line="$(printf '%s' "$match_line" | sed 's/^[[:space:]]*//')"

    # Truncate if too long
    if [[ "${#match_line}" -gt 50 ]]; then
        match_line="${match_line:0:47}..."
    fi

    printf '%s' "$match_line"
}

# ---------------------------------------------------------------------------
# _search_field_match <query> <field> <file>
#   Returns 0 if the specified frontmatter field contains the query string
#   (case-insensitive).
# ---------------------------------------------------------------------------
_search_field_match() {
    local query="$1"
    local field="$2"
    local file="$3"
    local value
    value="$(_search_get_fm_field "$field" "$file")"

    # Case-insensitive match using parameter expansion
    local lower_value lower_query
    lower_value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    lower_query="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')"

    if [[ "$lower_value" == *"$lower_query"* ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# _supports_color
#   Returns 0 if the terminal supports color output.
# ---------------------------------------------------------------------------
_supports_color() {
    if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# _highlight <text> <query>
#   If color is supported, highlights the query within text.
# ---------------------------------------------------------------------------
_highlight() {
    local text="$1"
    local query="$2"

    if _supports_color; then
        # Use sed for case-insensitive highlight with ANSI codes
        printf '%s' "$text" | sed "s/${query}/$(printf '\033[1;33m')&$(printf '\033[0m')/gI" 2>/dev/null || printf '%s' "$text"
    else
        printf '%s' "$text"
    fi
}

# ---------------------------------------------------------------------------
# kb_search <query> [OPTIONS]
#   Search vault entries.
#   Options:
#     --field <field>   Search only in a specific frontmatter field
#     --tier <tier>     Limit to a specific tier
#     --archive         Include archive/ tier in search
#     --tags <tag>      Filter results by tag
# ---------------------------------------------------------------------------
kb_search() {
    if [[ -z "${VAULT_ROOT:-}" ]]; then
        printf 'Error: VAULT_ROOT is not set\n' >&2
        return 1
    fi

    local query=""
    local field=""
    local tier_filter=""
    local include_archive=0
    local tag_filter=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --field)
                if [[ $# -lt 2 ]]; then
                    printf 'Error: --field requires a value\n' >&2
                    return 1
                fi
                field="$2"
                shift 2
                ;;
            --tier)
                if [[ $# -lt 2 ]]; then
                    printf 'Error: --tier requires a value\n' >&2
                    return 1
                fi
                tier_filter="$2"
                shift 2
                ;;
            --archive)
                include_archive=1
                shift
                ;;
            --tags)
                if [[ $# -lt 2 ]]; then
                    printf 'Error: --tags requires a value\n' >&2
                    return 1
                fi
                tag_filter="$2"
                shift 2
                ;;
            -*)
                printf 'search: unknown option: %s\n' "$1" >&2
                return 1
                ;;
            *)
                if [[ -z "$query" ]]; then
                    query="$1"
                else
                    printf 'search: unexpected argument: %s\n' "$1" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$query" ]]; then
        printf 'Usage: kb search <query> [--field <field>] [--tier <tier>] [--archive] [--tags <tag>]\n' >&2
        return 1
    fi

    # Sanitize query - reject characters that could break grep
    # Allow alphanumeric, spaces, hyphens, underscores, dots, and basic punctuation
    if [[ "$query" =~ [^a-zA-Z0-9\ _.\-/,:@\#\+] ]]; then
        printf 'Error: query contains unsupported characters\n' >&2
        return 1
    fi

    # Build tier list
    local tiers=()
    if [[ -n "$tier_filter" ]]; then
        tiers=("$tier_filter")
    else
        tiers=("${SEARCH_DEFAULT_TIERS[@]}")
        if [[ "$include_archive" -eq 1 ]]; then
            tiers+=("archive")
        fi
    fi

    # Search across tiers
    local results=""
    local match_count=0

    local tier
    for tier in "${tiers[@]}"; do
        local tier_dir="${VAULT_ROOT}/${tier}"
        [[ -d "$tier_dir" ]] || continue

        while IFS= read -r -d '' file; do
            local matched=0

            # Field-specific search
            if [[ -n "$field" ]]; then
                if _search_field_match "$query" "$field" "$file"; then
                    matched=1
                fi
            else
                # Full content + frontmatter search (case-insensitive)
                if grep -qi "$query" "$file" 2>/dev/null; then
                    matched=1
                fi
            fi

            [[ "$matched" -eq 0 ]] && continue

            # Tag filter
            if [[ -n "$tag_filter" ]]; then
                if ! _search_has_tag "$tag_filter" "$file"; then
                    continue
                fi
            fi

            # Collect result
            local entry_id
            entry_id="$(_search_get_fm_field "id" "$file")"
            local entry_title
            entry_title="$(_search_get_fm_field "title" "$file")"
            local context
            context="$(_search_match_context "$query" "$file")"

            if [[ -z "$entry_id" ]]; then
                entry_id="$(basename "$file" .md)"
            fi

            results="${results}${entry_id}|${entry_title}|${tier}|${context}"$'\n'
            match_count=$((match_count + 1))
        done < <(find "$tier_dir" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)
    done

    # ------------------------------------------------------------------
    # Output results
    # ------------------------------------------------------------------
    printf '\n'

    if [[ "$match_count" -eq 0 ]]; then
        printf 'No results found for: %s\n\n' "$query"
        return 0
    fi

    printf 'Found %d result(s) for: %s\n\n' "$match_count" "$query"

    # Table header
    printf '%-20s %-30s %-10s %s\n' "ID" "Title" "Tier" "Context"
    printf '%-20s %-30s %-10s %s\n' "---" "-----" "----" "-------"

    while IFS='|' read -r rid rtitle rtier rcontext; do
        [[ -z "$rid" ]] && continue

        # Truncate long values
        if [[ "${#rtitle}" -gt 28 ]]; then
            rtitle="${rtitle:0:25}..."
        fi
        if [[ "${#rcontext}" -gt 50 ]]; then
            rcontext="${rcontext:0:47}..."
        fi

        # Apply highlighting to context
        local highlighted_ctx
        highlighted_ctx="$(_highlight "$rcontext" "$query")"

        printf '%-20s %-30s %-10s %s\n' "$rid" "$rtitle" "$rtier" "$highlighted_ctx"
    done <<< "$results"

    printf '\n'
}

# Allow direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    kb_search "$@"
fi
