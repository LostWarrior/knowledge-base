#!/usr/bin/env bash
# lib/validate.sh - Validate frontmatter and structural integrity of vault entries
# Requires: VAULT_ROOT (set by dispatcher)

# Required frontmatter fields for every entry
readonly VALIDATE_REQUIRED_FIELDS=(id title status type domain created updated summary)

# Valid tier directories and their expected status values
declare -A VALIDATE_TIER_STATUS=(
    [active]="active"
    [reference]="reference"
    [learning]="learning"
    [tooling]="tooling"
    [archive]="archived"
)

# ---------------------------------------------------------------------------
# _extract_frontmatter <file>
#   Extracts the YAML frontmatter block (between --- delimiters) from a file.
#   Prints lines between the first and second '---' markers.
# ---------------------------------------------------------------------------
_extract_frontmatter() {
    local file="$1"
    local in_frontmatter=0
    local line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if [[ "$line" == "---" ]]; then
            if [[ "$in_frontmatter" -eq 0 ]]; then
                # First delimiter - start of frontmatter (must be line 1)
                if [[ "$line_num" -ne 1 ]]; then
                    return 1
                fi
                in_frontmatter=1
                continue
            else
                # Second delimiter - end of frontmatter
                return 0
            fi
        fi
        if [[ "$in_frontmatter" -eq 1 ]]; then
            printf '%s\n' "$line"
        fi
    done < "$file"

    # If we reach here, we never found the closing ---
    return 1
}

# ---------------------------------------------------------------------------
# _get_field <field> <frontmatter_text>
#   Extracts a scalar field value from frontmatter text.
#   Strips surrounding quotes and whitespace.
# ---------------------------------------------------------------------------
_get_field() {
    local field="$1"
    local fm="$2"
    local value

    value="$(printf '%s\n' "$fm" | sed -n "s/^${field}:[[:space:]]*//p" | head -n 1)"
    # Strip surrounding quotes
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    # Trim whitespace
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# _check_internal_links <file> <vault_root>
#   Scans markdown body for [text](path) links and verifies targets exist.
#   Returns broken links as newline-separated strings.
# ---------------------------------------------------------------------------
_check_internal_links() {
    local file="$1"
    local vault_root="$2"
    local file_dir
    file_dir="$(dirname "$file")"
    local broken=""

    # Extract link targets from markdown (skip external URLs)
    while IFS= read -r link_target; do
        # Skip empty, external URLs, and anchors
        if [[ -z "$link_target" ]] || [[ "$link_target" =~ ^https?:// ]] || [[ "$link_target" == "#"* ]]; then
            continue
        fi

        # Strip any anchor fragment
        link_target="${link_target%%#*}"
        [[ -z "$link_target" ]] && continue

        # Resolve the target path relative to the file's directory
        local resolved
        if [[ "$link_target" == /* ]]; then
            # Absolute path within vault
            resolved="${vault_root}/${link_target#/}"
        else
            resolved="${file_dir}/${link_target}"
        fi

        if [[ ! -e "$resolved" ]]; then
            broken="${broken}${link_target}"$'\n'
        fi
    done < <(grep -oE '\[[^]]*\]\([^)]+\)' "$file" 2>/dev/null | sed 's/.*](\([^)]*\))/\1/')

    printf '%s' "$broken"
}

# ---------------------------------------------------------------------------
# kb_validate [--quiet]
#   Main validation function. Scans all tier directories for .md files and
#   performs structural and content checks.
#   --quiet: suppress per-file output, only show summary
# ---------------------------------------------------------------------------
kb_validate() {
    local quiet=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quiet) quiet=1; shift ;;
            *) printf 'validate: unknown option: %s\n' "$1" >&2; return 1 ;;
        esac
    done

    if [[ -z "${VAULT_ROOT:-}" ]]; then
        printf 'Error: VAULT_ROOT is not set\n' >&2
        return 1
    fi

    local error_count=0
    local warning_count=0
    local file_count=0
    local errors=""
    local warnings=""

    # Collect all known IDs for duplicate detection
    # Key: id, Value: file path
    declare -A seen_ids

    local tier
    for tier in "${!VALIDATE_TIER_STATUS[@]}"; do
        local tier_dir="${VAULT_ROOT}/${tier}"
        [[ -d "$tier_dir" ]] || continue

        while IFS= read -r -d '' file; do
            file_count=$((file_count + 1))
            local basename_noext
            basename_noext="$(basename "$file" .md)"
            local rel_path="${file#"${VAULT_ROOT}/"}"

            # ----------------------------------------------------------
            # Check 1: Has YAML frontmatter
            # ----------------------------------------------------------
            local fm
            if ! fm="$(_extract_frontmatter "$file")"; then
                errors="${errors}  ERROR [${rel_path}]: Missing or malformed YAML frontmatter\n"
                error_count=$((error_count + 1))
                continue
            fi

            if [[ -z "$fm" ]]; then
                errors="${errors}  ERROR [${rel_path}]: Frontmatter block is empty\n"
                error_count=$((error_count + 1))
                continue
            fi

            # ----------------------------------------------------------
            # Check 2: Required fields present
            # ----------------------------------------------------------
            local field
            for field in "${VALIDATE_REQUIRED_FIELDS[@]}"; do
                local value
                value="$(_get_field "$field" "$fm")"
                if [[ -z "$value" ]]; then
                    errors="${errors}  ERROR [${rel_path}]: Missing required field '${field}'\n"
                    error_count=$((error_count + 1))
                fi
            done

            # ----------------------------------------------------------
            # Check 3: id matches filename
            # ----------------------------------------------------------
            local file_id
            file_id="$(_get_field "id" "$fm")"
            if [[ -n "$file_id" ]] && [[ "$file_id" != "$basename_noext" ]]; then
                errors="${errors}  ERROR [${rel_path}]: id '${file_id}' does not match filename '${basename_noext}'\n"
                error_count=$((error_count + 1))
            fi

            # ----------------------------------------------------------
            # Check 4: Status matches tier directory
            # ----------------------------------------------------------
            local file_status
            file_status="$(_get_field "status" "$fm")"
            local expected_status="${VALIDATE_TIER_STATUS[$tier]}"
            if [[ -n "$file_status" ]] && [[ "$file_status" != "$expected_status" ]]; then
                warnings="${warnings}  WARN  [${rel_path}]: status '${file_status}' does not match tier '${tier}' (expected '${expected_status}')\n"
                warning_count=$((warning_count + 1))
            fi

            # ----------------------------------------------------------
            # Check 5: Broken internal links
            # ----------------------------------------------------------
            local broken_links
            broken_links="$(_check_internal_links "$file" "$VAULT_ROOT")"
            if [[ -n "$broken_links" ]]; then
                while IFS= read -r broken; do
                    [[ -z "$broken" ]] && continue
                    warnings="${warnings}  WARN  [${rel_path}]: Broken link -> ${broken}\n"
                    warning_count=$((warning_count + 1))
                done <<< "$broken_links"
            fi

            # ----------------------------------------------------------
            # Check 6: Duplicate IDs
            # ----------------------------------------------------------
            if [[ -n "$file_id" ]]; then
                if [[ -n "${seen_ids[$file_id]+set}" ]]; then
                    errors="${errors}  ERROR [${rel_path}]: Duplicate id '${file_id}' (also in ${seen_ids[$file_id]})\n"
                    error_count=$((error_count + 1))
                else
                    seen_ids["$file_id"]="$rel_path"
                fi
            fi

        done < <(find "$tier_dir" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)
    done

    # ------------------------------------------------------------------
    # Output results
    # ------------------------------------------------------------------
    if [[ "$quiet" -eq 0 ]]; then
        printf '\n--- kb validate ---\n\n'

        if [[ -n "$errors" ]]; then
            printf 'Errors:\n'
            printf '%b' "$errors"
            printf '\n'
        fi

        if [[ -n "$warnings" ]]; then
            printf 'Warnings:\n'
            printf '%b' "$warnings"
            printf '\n'
        fi
    fi

    printf 'Scanned %d files across %d tiers: %d errors, %d warnings\n' \
        "$file_count" "${#VALIDATE_TIER_STATUS[@]}" "$error_count" "$warning_count"

    if [[ "$error_count" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Allow direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    kb_validate "$@"
fi
