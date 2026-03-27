#!/usr/bin/env bash
# lib/search.sh - Search vault entries across frontmatter and content
# Requires: VAULT_ROOT (set by dispatcher)

# Tiers to search by default (archive excluded unless --archive)
readonly SEARCH_DEFAULT_TIERS=(active reference learning tooling)
readonly SEARCH_ALLOWED_TIERS=(active reference learning tooling archive)
readonly SEARCH_JSON_SCHEMA_VERSION=1

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
# _search_trim <string>
#   Trims leading and trailing ASCII whitespace.
# ---------------------------------------------------------------------------
_search_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# _search_json_escape <string>
#   Escapes a string for safe JSON embedding.
# ---------------------------------------------------------------------------
_search_json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/}"
    str="${str//$'\t'/\\t}"
    printf '%s' "$str"
}

# ---------------------------------------------------------------------------
# _search_json_array_from_csv <csv>
#   Converts a comma-separated string to a JSON array literal.
# ---------------------------------------------------------------------------
_search_json_array_from_csv() {
    local raw="$1"
    raw="${raw#\[}"
    raw="${raw%\]}"

    if [[ -z "$raw" ]]; then
        printf '[]'
        return
    fi

    local first=1
    local IFS=','
    printf '['
    local item
    for item in $raw; do
        item="$(_search_trim "$item")"
        [[ -z "$item" ]] && continue
        if [[ "$first" -eq 0 ]]; then
            printf ','
        fi
        first=0
        printf '"%s"' "$(_search_json_escape "$item")"
    done
    printf ']'
}

# ---------------------------------------------------------------------------
# _search_valid_name <value>
#   Validates names used for frontmatter fields and tier selection.
# ---------------------------------------------------------------------------
_search_valid_name() {
    local value="$1"
    [[ "$value" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]]
}

# ---------------------------------------------------------------------------
# _search_allowed_tier <value>
#   Returns 0 if the tier is one of the supported vault tiers.
# ---------------------------------------------------------------------------
_search_allowed_tier() {
    local tier="$1"
    case "$tier" in
        active|reference|learning|tooling|archive)
            return 0
            ;;
    esac
    return 1
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
#     --json          Emit structured JSON output
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
    local json_mode=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                json_mode=1
                shift
                ;;
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
        printf 'Usage: kb search <query> [--json] [--field <field>] [--tier <tier>] [--archive] [--tags <tag>]\n' >&2
        return 1
    fi

    # Sanitize query - reject characters that could break grep or the shell.
    # Allow alphanumeric, whitespace, and a small set of punctuation used in note titles.
    case "$query" in
        *[![:alnum:][:space:]._/,:@#+-]*)
            printf 'Error: query contains unsupported characters\n' >&2
            return 1
            ;;
    esac

    if [[ -n "$field" ]] && ! _search_valid_name "$field"; then
        printf 'Error: invalid field name: %s\n' "$field" >&2
        return 1
    fi

    if [[ -n "$tier_filter" ]]; then
        if ! _search_allowed_tier "$tier_filter"; then
            printf 'Error: invalid tier: %s\n' "$tier_filter" >&2
            return 1
        fi
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
    local -a result_ids=()
    local -a result_titles=()
    local -a result_tiers=()
    local -a result_statuses=()
    local -a result_types=()
    local -a result_domains=()
    local -a result_paths=()
    local -a result_createds=()
    local -a result_updateds=()
    local -a result_summaries=()
    local -a result_contexts=()
    local -a result_tags=()
    local -a result_match_scopes=()
    local match_count=0

    local tier
    for tier in "${tiers[@]}"; do
        local tier_dir="${VAULT_ROOT}/${tier}"
        [[ -d "$tier_dir" ]] || continue

        while IFS= read -r -d '' file; do
            local matched=0
            local match_scope="content"

            # Field-specific search
            if [[ -n "$field" ]]; then
                if _search_field_match "$query" "$field" "$file"; then
                    matched=1
                    match_scope="field:${field}"
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
            local entry_status
            entry_status="$(_search_get_fm_field "status" "$file")"
            local entry_type
            entry_type="$(_search_get_fm_field "type" "$file")"
            local entry_domain
            entry_domain="$(_search_get_fm_field "domain" "$file")"
            local entry_created
            entry_created="$(_search_get_fm_field "created" "$file")"
            local entry_updated
            entry_updated="$(_search_get_fm_field "updated" "$file")"
            local entry_summary
            entry_summary="$(_search_get_fm_field "summary" "$file")"
            local entry_tags
            entry_tags="$(_search_get_tags "$file")"
            local context
            context="$(_search_match_context "$query" "$file")"
            local entry_path
            entry_path="${tier}/$(basename "$file")"

            if [[ -z "$entry_id" ]]; then
                entry_id="$(basename "$file" .md)"
            fi

            result_ids+=("$entry_id")
            result_titles+=("$entry_title")
            result_tiers+=("$tier")
            result_statuses+=("$entry_status")
            result_types+=("$entry_type")
            result_domains+=("$entry_domain")
            result_paths+=("$entry_path")
            result_createds+=("$entry_created")
            result_updateds+=("$entry_updated")
            result_summaries+=("$entry_summary")
            result_contexts+=("$context")
            result_tags+=("$entry_tags")
            result_match_scopes+=("$match_scope")
            match_count=$((match_count + 1))
        done < <(find "$tier_dir" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)
    done

    # ------------------------------------------------------------------
    # Output results
    # ------------------------------------------------------------------
    if [[ "$json_mode" -eq 1 ]]; then
        printf '{"schema_version":%d,"query":"%s","count":%d,"results":[' \
            "$SEARCH_JSON_SCHEMA_VERSION" "$(_search_json_escape "$query")" "$match_count"

        local i
        for ((i = 0; i < match_count; i++)); do
            if [[ "$i" -gt 0 ]]; then
                printf ','
            fi
            printf '{"id":"%s","title":"%s","status":"%s","tier":"%s","type":"%s","domain":"%s","path":"%s","created":"%s","updated":"%s","summary":"%s","context":"%s","match_scope":"%s","tags":%s}' \
                "$(_search_json_escape "${result_ids[$i]}")" \
                "$(_search_json_escape "${result_titles[$i]}")" \
                "$(_search_json_escape "${result_statuses[$i]}")" \
                "$(_search_json_escape "${result_tiers[$i]}")" \
                "$(_search_json_escape "${result_types[$i]}")" \
                "$(_search_json_escape "${result_domains[$i]}")" \
                "$(_search_json_escape "${result_paths[$i]}")" \
                "$(_search_json_escape "${result_createds[$i]}")" \
                "$(_search_json_escape "${result_updateds[$i]}")" \
                "$(_search_json_escape "${result_summaries[$i]}")" \
                "$(_search_json_escape "${result_contexts[$i]}")" \
                "$(_search_json_escape "${result_match_scopes[$i]}")" \
                "$(_search_json_array_from_csv "${result_tags[$i]}")"
        done
        printf ']}\n'
        return 0
    fi

    printf '\n'

    if [[ "$match_count" -eq 0 ]]; then
        printf 'No results found for: %s\n\n' "$query"
        return 0
    fi

    printf 'Found %d result(s) for: %s\n\n' "$match_count" "$query"

    # Table header
    printf '%-20s %-30s %-10s %s\n' "ID" "Title" "Tier" "Context"
    printf '%-20s %-30s %-10s %s\n' "---" "-----" "----" "-------"

    local i
    for ((i = 0; i < match_count; i++)); do

        # Truncate long values
        local rid rtitle rtier rcontext
        rid="${result_ids[$i]}"
        rtitle="${result_titles[$i]}"
        rtier="${result_tiers[$i]}"
        rcontext="${result_contexts[$i]}"
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
    done

    printf '\n'
}

# Allow direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    kb_search "$@"
fi
