#!/usr/bin/env bash
# lib/add.sh - Add a new entry to the kb vault
# Requires: VAULT_ROOT, KB_ROOT

# Validate a path is safe (no path traversal)
_validate_path() {
    local path="$1"
    if [[ "$path" == *".."* ]]; then
        printf 'Error: path traversal ("..") is not allowed\n' >&2
        return 1
    fi
    return 0
}

# Validate an ID matches the safe pattern
_validate_id() {
    local id="$1"
    if [[ ! "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        printf 'Error: invalid id "%s" - must match ^[a-z0-9][a-z0-9-]*$\n' "$id" >&2
        return 1
    fi
    return 0
}

# Convert a title to a safe id
_title_to_id() {
    local title="$1"
    local id

    # Lowercase, replace spaces with hyphens, strip non-alphanumeric
    id="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | tr -s '-')"
    # Strip leading/trailing hyphens
    id="${id#-}"
    id="${id%-}"
    # Truncate to 50 characters
    id="$(printf '%s' "$id" | cut -c1-50)"
    # Strip trailing hyphen after truncation
    id="${id%-}"

    printf '%s' "$id"
}

# Map a status value to its tier directory
_status_to_tier() {
    local status="$1"
    case "$status" in
        active)    printf 'active' ;;
        reference) printf 'reference' ;;
        archived)  printf 'archive' ;;
        *)         printf '%s' "$status" ;;
    esac
}

kb_add() {
    local title=""
    local status="active"
    local entry_type="analysis"
    local domain="general"
    local tags=""
    local projects=""
    local summary=""
    local open_editor=0
    local ttl="90d"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title)
                title="$2"
                shift 2
                ;;
            --status)
                status="$2"
                shift 2
                ;;
            --type)
                entry_type="$2"
                shift 2
                ;;
            --domain)
                domain="$2"
                shift 2
                ;;
            --tags)
                tags="$2"
                shift 2
                ;;
            --projects)
                projects="$2"
                shift 2
                ;;
            --summary)
                summary="$2"
                shift 2
                ;;
            --ttl)
                ttl="$2"
                shift 2
                ;;
            --edit)
                open_editor=1
                shift
                ;;
            -*)
                printf 'Error: unknown flag: %s\n' "$1" >&2
                return 1
                ;;
            *)
                # Positional argument is the title
                if [[ -z "$title" ]]; then
                    title="$1"
                else
                    printf 'Error: unexpected argument: %s\n' "$1" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    # Default summary from title if not provided
    if [[ -z "$summary" ]]; then
        summary="$title"
    fi

    # Title is required
    if [[ -z "$title" ]]; then
        printf 'Error: title is required\n' >&2
        printf 'Usage: kb add "My Entry Title" [--status active] [--type analysis] ...\n' >&2
        return 1
    fi

    # Ensure VAULT_ROOT is set
    if [[ -z "${VAULT_ROOT:-}" ]]; then
        printf 'Error: VAULT_ROOT is not set - are you in a kb vault?\n' >&2
        return 1
    fi

    _validate_path "$VAULT_ROOT" || return 1

    # Generate id from title
    local id
    id="$(_title_to_id "$title")"

    if [[ -z "$id" ]]; then
        printf 'Error: could not generate a valid id from title "%s"\n' "$title" >&2
        return 1
    fi

    _validate_id "$id" || return 1

    # Check for duplicate id across all tiers
    local tiers=( "active" "reference" "learning" "tooling" "archive" )
    for tier in "${tiers[@]}"; do
        local tier_dir="$VAULT_ROOT/$tier"
        if [[ -d "$tier_dir" ]] && [[ -f "$tier_dir/$id.md" ]]; then
            printf 'Error: entry with id "%s" already exists at %s/%s.md\n' "$id" "$tier" "$id" >&2
            return 1
        fi
    done

    # Validate status maps to a real tier directory
    local target_tier
    target_tier="$(_status_to_tier "$status")"
    local target_dir="$VAULT_ROOT/$target_tier"

    if [[ ! -d "$target_dir" ]]; then
        printf 'Error: tier directory "%s" does not exist\n' "$target_tier" >&2
        return 1
    fi

    local today
    today="$(date +%Y-%m-%d)"

    # Format tags as YAML list: [tag1, tag2]
    local tags_yaml="[]"
    if [[ -n "$tags" ]]; then
        # Convert comma-separated to YAML array
        local formatted=""
        local IFS=','
        local first=1
        for tag in $tags; do
            # Trim whitespace
            tag="$(printf '%s' "$tag" | tr -d '[:space:]')"
            if [[ -n "$tag" ]]; then
                if [[ "$first" -eq 1 ]]; then
                    formatted="$tag"
                    first=0
                else
                    formatted="$formatted, $tag"
                fi
            fi
        done
        unset IFS
        if [[ -n "$formatted" ]]; then
            tags_yaml="[$formatted]"
        fi
    fi

    # Format projects as YAML list
    local projects_yaml="[]"
    if [[ -n "$projects" ]]; then
        local formatted=""
        local IFS=','
        local first=1
        for proj in $projects; do
            proj="$(printf '%s' "$proj" | tr -d '[:space:]')"
            if [[ -n "$proj" ]]; then
                if [[ "$first" -eq 1 ]]; then
                    formatted="$proj"
                    first=0
                else
                    formatted="$formatted, $proj"
                fi
            fi
        done
        unset IFS
        if [[ -n "$formatted" ]]; then
            projects_yaml="[$formatted]"
        fi
    fi

    # Build the entry from template or inline
    local output_file="$target_dir/$id.md"
    local template="$KB_ROOT/templates/entry.md"

    if [[ -f "$template" ]]; then
        # Read template and replace placeholders
        local content
        content="$(cat "$template")"
        content="${content//__ID__/$id}"
        content="${content//__TITLE__/$title}"
        content="${content//__STATUS__/$status}"
        content="${content//__TYPE__/$entry_type}"
        content="${content//__DOMAIN__/$domain}"
        content="${content//__DATE__/$today}"
        content="${content//__TTL__/$ttl}"

        # Write to temp file then move (atomic-ish)
        local tmpfile
        tmpfile="$(mktemp)"
        printf '%s\n' "$content" > "$tmpfile"

        # Replace the placeholder arrays with actual values using sed
        sed -i.bak "s/^projects: \[\]/projects: $projects_yaml/" "$tmpfile"
        sed -i.bak "s/^tags: \[\]/tags: $tags_yaml/" "$tmpfile"
        sed -i.bak "s/^summary: \"\"/summary: \"$summary\"/" "$tmpfile"
        rm -f "$tmpfile.bak"

        mv "$tmpfile" "$output_file"
    else
        printf 'Error: entry template not found at %s\n' "$template" >&2
        return 1
    fi

    printf 'Created: %s\n' "$output_file"

    # Auto-run index if the function is available
    if declare -f kb_index > /dev/null 2>&1; then
        kb_index
    fi

    # Open in editor if requested
    if [[ "$open_editor" -eq 1 ]]; then
        local editor="${EDITOR:-vi}"
        "$editor" "$output_file"
    fi
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    kb_add "$@"
fi
