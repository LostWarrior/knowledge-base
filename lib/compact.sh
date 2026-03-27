#!/usr/bin/env bash
# lib/compact.sh - Compact multiple entries into a single summary file
# Requires: VAULT_ROOT

# Validate a path is safe (no path traversal)
_validate_path() {
    local path="$1"
    if [[ "$path" == *".."* ]]; then
        printf 'Error: path traversal ("..") is not allowed\n' >&2
        return 1
    fi
    return 0
}

# Extract a section from a markdown file by heading
# Returns content under the heading until the next heading of same or higher level
_extract_section() {
    local file="$1"
    local heading="$2"
    local in_section=0
    local result=""

    while IFS= read -r line; do
        if [[ "$in_section" -eq 1 ]]; then
            # Stop at next heading of same or higher level (## or #)
            if [[ "$line" =~ ^##?[[:space:]] ]] && [[ "$line" != "### "* ]]; then
                break
            fi
            result="${result}${line}"$'\n'
        fi
        if [[ "$line" == "## $heading" ]] || [[ "$line" == "## $heading "* ]]; then
            in_section=1
        fi
    done < "$file"

    # Output result (trim is not critical for a draft)
    printf '%s' "$result"
}

# Extract the title from frontmatter
_fm_title() {
    local file="$1"
    sed -n '/^---$/,/^---$/{ /^title:/{ s/^title: *//; s/^"//; s/"$//; p; }; }' "$file"
}

# Extract TL;DR or summary from frontmatter
_fm_summary() {
    local file="$1"
    sed -n '/^---$/,/^---$/{ /^summary:/{ s/^summary: *//; s/^"//; s/"$//; p; }; }' "$file"
}

kb_compact() {
    local source_dir=""
    local output_file=""
    local archive_dir=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --into)
                output_file="$2"
                shift 2
                ;;
            --archive-to)
                archive_dir="$2"
                shift 2
                ;;
            -*)
                printf 'Error: unknown flag: %s\n' "$1" >&2
                printf 'Usage: kb compact <directory> --into <output-file> [--archive-to <dir>]\n' >&2
                return 1
                ;;
            *)
                if [[ -z "$source_dir" ]]; then
                    source_dir="$1"
                else
                    printf 'Error: unexpected argument: %s\n' "$1" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$source_dir" ]] || [[ -z "$output_file" ]]; then
        printf 'Usage: kb compact <directory> --into <output-file> [--archive-to <dir>]\n' >&2
        return 1
    fi

    # Validate paths
    _validate_path "$source_dir" || return 1
    _validate_path "$output_file" || return 1
    if [[ -n "$archive_dir" ]]; then
        _validate_path "$archive_dir" || return 1
    fi

    # Resolve paths relative to VAULT_ROOT if not absolute
    if [[ "$source_dir" != /* ]]; then
        source_dir="${VAULT_ROOT:-.}/$source_dir"
    fi
    if [[ "$output_file" != /* ]]; then
        output_file="${VAULT_ROOT:-.}/$output_file"
    fi
    if [[ -n "$archive_dir" ]] && [[ "$archive_dir" != /* ]]; then
        archive_dir="${VAULT_ROOT:-.}/$archive_dir"
    fi

    if [[ ! -d "$source_dir" ]]; then
        printf 'Error: source directory does not exist: %s\n' "$source_dir" >&2
        return 1
    fi

    # Warn if output file already exists
    if [[ -f "$output_file" ]]; then
        printf 'Warning: output file already exists and will be overwritten: %s\n' "$output_file" >&2
    fi

    # Collect all markdown files in source directory
    local source_files=()
    for mdfile in "$source_dir"/*.md; do
        [[ -f "$mdfile" ]] || continue
        source_files+=("$mdfile")
    done

    if [[ ${#source_files[@]} -eq 0 ]]; then
        printf 'Error: no .md files found in %s\n' "$source_dir" >&2
        return 1
    fi

    printf 'Compacting %d files from %s\n' "${#source_files[@]}" "$source_dir"

    local today
    today="$(date +%Y-%m-%d)"

    # Collect content sections
    local context_parts=""
    local findings_parts=""
    local decisions_parts=""
    local artifacts_parts=""
    local source_list=""

    for mdfile in "${source_files[@]}"; do
        local filename
        filename="$(basename "$mdfile")"
        local title
        title="$(_fm_title "$mdfile")"
        local summary
        summary="$(_fm_summary "$mdfile")"

        if [[ -z "$title" ]]; then
            title="$filename"
        fi

        source_list="${source_list}- ${filename}"
        if [[ -n "$summary" ]]; then
            source_list="${source_list} - ${summary}"
        fi
        source_list="${source_list}"$'\n'

        # Extract sections (silently skip if not found)
        local ctx
        ctx="$(_extract_section "$mdfile" "Context")"
        if [[ -n "$ctx" ]]; then
            context_parts="${context_parts}### From: ${title}"$'\n\n'"${ctx}"$'\n\n'
        fi

        local find
        find="$(_extract_section "$mdfile" "Key Findings")"
        if [[ -n "$find" ]]; then
            findings_parts="${findings_parts}### From: ${title}"$'\n\n'"${find}"$'\n\n'
        fi

        local dec
        dec="$(_extract_section "$mdfile" "Decision Log")"
        if [[ -n "$dec" ]]; then
            decisions_parts="${decisions_parts}### From: ${title}"$'\n\n'"${dec}"$'\n\n'
        fi

        local art
        art="$(_extract_section "$mdfile" "Artifacts")"
        if [[ -n "$art" ]]; then
            artifacts_parts="${artifacts_parts}### From: ${title}"$'\n\n'"${art}"$'\n\n'
        fi
    done

    # Generate output filename-based id
    local output_basename
    output_basename="$(basename "$output_file" .md)"

    # Write the compacted file
    local tmpfile
    tmpfile="$(mktemp)"

    {
        printf -- '---\n'
        printf 'id: %s\n' "$output_basename"
        printf 'title: "Compacted: %s"\n' "$output_basename"
        printf 'status: reference\n'
        printf 'type: report\n'
        printf 'domain: general\n'
        printf 'projects: []\n'
        printf 'created: %s\n' "$today"
        printf 'updated: %s\n' "$today"
        printf 'ttl: 180d\n'
        printf 'tags: [compacted]\n'
        printf 'summary: "Compacted from %d entries in %s"\n' "${#source_files[@]}" "$(basename "$source_dir")"
        printf -- '---\n\n'

        printf '# Compacted: %s\n\n' "$output_basename"
        # shellcheck disable=SC2016
        printf '> This is a draft produced by `kb compact`. Review and edit before finalizing.\n\n'

        printf '## Sources\n\n'
        printf '%s\n' "$source_list"

        printf '## Context\n\n'
        if [[ -n "$context_parts" ]]; then
            printf '%s\n' "$context_parts"
        else
            printf '_No context sections found in source files._\n\n'
        fi

        printf '## Key Findings\n\n'
        if [[ -n "$findings_parts" ]]; then
            printf '%s\n' "$findings_parts"
        else
            printf '_No key findings sections found in source files._\n\n'
        fi

        printf '## Decision Log\n\n'
        if [[ -n "$decisions_parts" ]]; then
            printf '%s\n' "$decisions_parts"
        else
            printf '_No decision log sections found in source files._\n\n'
        fi

        printf '## Artifacts\n\n'
        if [[ -n "$artifacts_parts" ]]; then
            printf '%s\n' "$artifacts_parts"
        else
            printf '_No artifact sections found in source files._\n\n'
        fi
    } > "$tmpfile"

    # Ensure output directory exists
    mkdir -p "$(dirname "$output_file")"
    mv "$tmpfile" "$output_file"

    printf 'Draft written to: %s\n' "$output_file"
    printf 'Please review and edit the compacted file before finalizing.\n'

    # Optionally archive source files
    if [[ -n "$archive_dir" ]]; then
        mkdir -p "$archive_dir"
        local moved=0
        for mdfile in "${source_files[@]}"; do
            local fname
            fname="$(basename "$mdfile")"
            mv "$mdfile" "$archive_dir/$fname"
            moved=$((moved + 1))
        done
        printf 'Archived %d source files to %s\n' "$moved" "$archive_dir"
    fi
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    kb_compact "$@"
fi
