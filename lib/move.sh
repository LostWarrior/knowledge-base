#!/usr/bin/env bash
# lib/move.sh - Move an entry between tiers
# Requires: VAULT_ROOT

# shellcheck source=/dev/null
source "${KB_ROOT}/lib/_vault_state.sh"

# Validate an ID matches the safe pattern
_validate_id() {
    local id="$1"
    if [[ ! "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        printf 'Error: invalid id "%s" - must match ^[a-z0-9][a-z0-9-]*$\n' "$id" >&2
        return 1
    fi
    return 0
}

# Map a tier directory name to the frontmatter status value
_tier_to_fm_status() {
    local tier="$1"
    case "$tier" in
        active)    printf 'active' ;;
        reference) printf 'reference' ;;
        learning)  printf 'learning' ;;
        tooling)   printf 'tooling' ;;
        archive)   printf 'archived' ;;
        *)         printf '%s' "$tier" ;;
    esac
}

# Find an entry file by id across all tiers
# Prints the full path if found, empty string otherwise
_find_entry() {
    local id="$1"
    local tiers=( "active" "reference" "learning" "tooling" "archive" )

    for tier in "${tiers[@]}"; do
        local candidate="$VAULT_ROOT/$tier/$id.md"
        if [[ -f "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

kb_move() {
    local id=""
    local target_tier=""

    # Parse positional arguments
    if [[ $# -lt 2 ]]; then
        printf 'Usage: kb move <id> <target-tier>\n' >&2
        printf 'Tiers: active, reference, learning, tooling, archive\n' >&2
        return 1
    fi

    id="$1"
    target_tier="$2"

    # Ensure VAULT_ROOT is set
    if [[ -z "${VAULT_ROOT:-}" ]]; then
        printf 'Error: VAULT_ROOT is not set - are you in a kb vault?\n' >&2
        return 1
    fi

    # Validate id
    _validate_id "$id" || return 1

    # Validate target tier directory exists
    local target_dir="$VAULT_ROOT/$target_tier"
    if [[ ! -d "$target_dir" ]]; then
        printf 'Error: tier directory "%s" does not exist\n' "$target_tier" >&2
        printf 'Valid tiers: active, reference, learning, tooling, archive\n' >&2
        return 1
    fi

    # Find the source file
    local source_file
    source_file="$(_find_entry "$id")" || {
        printf 'Error: entry "%s" not found in any tier\n' "$id" >&2
        return 1
    }

    local source_dir
    source_dir="$(dirname "$source_file")"
    local source_tier
    source_tier="$(basename "$source_dir")"

    # Check if already in target tier
    if [[ "$source_tier" == "$target_tier" ]]; then
        printf 'Entry "%s" is already in %s/\n' "$id" "$target_tier"
        return 0
    fi

    local dest_file="$target_dir/$id.md"

    # Update frontmatter: status and updated date
    local new_status
    new_status="$(_tier_to_fm_status "$target_tier")"
    local today
    today="$(date +%Y-%m-%d)"

    local tmpfile
    tmpfile="$(mktemp)"

    # Use sed to update the status and updated fields within frontmatter
    sed -e '/^---$/,/^---$/{ s/^status: .*/status: '"$new_status"'/; s/^updated: .*/updated: '"$today"'/; }' \
        "$source_file" > "$tmpfile"

    # Move to destination
    mv "$tmpfile" "$dest_file"
    rm -f "$source_file"

    printf 'Moved "%s" from %s/ to %s/ (status: %s)\n' "$id" "$source_tier" "$target_tier" "$new_status"
    kb_refresh_indexes
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    kb_move "$@"
fi
