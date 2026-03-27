#!/usr/bin/env bash
# lib/_migrate_scan.sh - Phase 1: scan source directory and build migration plan
# Sourced by migrate.sh. Depends on _migrate_utils.sh, _migrate_parse.sh, _theme.sh.

_mig_scan() {
    local source_dir="$1" vault_root="$2" plan_file="$3" no_compact="$4"
    shift 4
    local -a excludes=("$@")

    local total=0 n_migrate=0 n_compact=0 n_archive=0 n_skip=0 n_warn=0

    _info "Scanning ${source_dir}..." >&2
    : > "$plan_file"

    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$source_dir" -type f -name '*.md' \
        -not -path '*/.git/*' -not -path '*/.kb/*' -print0 2>/dev/null | sort -z)

    local filepath rel_path fname parent_rel action target_tier target_id
    local title status type domain summary created updated tags project_dir notes
    local matched meta

    for filepath in "${files[@]}"; do
        rel_path="${filepath#"$source_dir"/}"
        fname="$(basename "$filepath")"
        total=$((total + 1))

        # --- Check exclude patterns ---
        matched=false
        for pat in "${excludes[@]}"; do
            # shellcheck disable=SC2254
            case "$rel_path" in $pat) matched=true; break ;; esac
        done
        if [[ "$matched" == "true" ]]; then
            _skip "Excluded: $rel_path" >&2
            n_skip=$((n_skip + 1))
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "skip" "$rel_path" "" "" "" "" "" "" "" "" "" "" "" "excluded" >> "$plan_file"
            continue
        fi

        # Reset per-file vars
        action="" target_tier="" target_id="" title="" status="" type="" domain=""
        summary="" created="" updated="" tags="" project_dir="" notes=""

        # --- Classify ---
        parent_rel="$(dirname "$rel_path")"

        # Root-level index files
        if [[ "$parent_rel" == "." ]] && _mig_is_index_file "$fname"; then
            action="skip"; notes="index file"

        # Files in subdirectories with compaction enabled
        elif [[ "$parent_rel" != "." && "$no_compact" != "true" ]]; then
            local abs_parent="${source_dir}/${parent_rel}"
            if _mig_is_project_dir "$abs_parent"; then
                project_dir="$parent_rel"
                if _mig_is_session_file "$fname"; then
                    action="archive"
                elif _mig_is_index_file "$fname"; then
                    action="skip"; notes="absorbed into compact"
                else
                    action="compact"
                fi
            fi
        fi

        # Session files at root (not yet classified)
        if [[ -z "$action" && "$parent_rel" == "." ]] && _mig_is_session_file "$fname"; then
            action="archive"
        fi

        # Default: standalone migrate
        if [[ -z "$action" ]]; then
            action="migrate"
        fi

        # --- Parse metadata for actionable files ---
        if [[ "$action" == "migrate" || "$action" == "compact" ]]; then
            meta="$(_mig_parse_file "$filepath")"
            IFS=$'\t' read -r title status type domain summary created updated tags _ <<< "$meta"

            target_id="$(_mig_title_to_id "$title")"

            # Idempotency check
            if _mig_id_exists "$target_id" "$vault_root"; then
                action="skip"; notes="already exists"
            else
                target_tier="$(_mig_status_to_tier "$status")"
            fi
        fi

        # Archive also needs minimal metadata
        if [[ "$action" == "archive" ]]; then
            meta="$(_mig_parse_file "$filepath")"
            IFS=$'\t' read -r title status type domain summary created updated tags _ <<< "$meta"
            target_tier="archive"
            target_id="$(_mig_title_to_id "$title")"
            if _mig_id_exists "$target_id" "$vault_root"; then
                action="skip"; notes="already exists"
            fi
        fi

        # --- Tally ---
        case "$action" in
            migrate) n_migrate=$((n_migrate + 1)) ;;
            compact) n_compact=$((n_compact + 1)) ;;
            archive) n_archive=$((n_archive + 1)) ;;
            skip)    n_skip=$((n_skip + 1)) ;;
        esac

        # --- Write plan line ---
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$action" "$rel_path" "$target_tier" "$target_id" "$title" \
            "$status" "$type" "$domain" "$summary" "$created" "$updated" \
            "$tags" "$project_dir" "$notes" >> "$plan_file"
    done

    _info "Scanned ${total} files: ${n_migrate} migrate, ${n_compact} compact, ${n_archive} archive, ${n_skip} skip" >&2

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$total" "$n_migrate" "$n_compact" "$n_archive" "$n_skip" "$n_warn"
}
