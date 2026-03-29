#!/usr/bin/env bash
# lib/_migrate_execute.sh - Phase 3: execute migration plan
# Sourced by migrate.sh. Depends on _migrate_utils.sh, _migrate_parse.sh, _theme.sh.

_mig_generate_frontmatter() {
    local title="$1" id="$2" status="$3" type="$4" domain="$5"
    local summary="$6" created="$7" updated="$8" tags="$9"
    printf -- '---\nid: %s\ntitle: "%s"\nstatus: %s\ntype: %s\ndomain: %s\n' \
        "$id" "$title" "$status" "$type" "$domain"
    printf 'projects: []\ncreated: %s\nupdated: %s\nttl: 90d\ntags: [%s]\nsummary: "%s"\n---\n' \
        "$created" "$updated" "$tags" "$summary"
}

_mig_transform_file() {
    local src="$1" out="$2" title="$3" id="$4" status="$5" type="$6"
    local domain="$7" summary="$8" created="$9" updated="${10}"
    local tags="${11}" method="${12}"
    local body
    body="$(cat "$src")"
    if [[ "$method" == "informal" ]]; then
        body="$(printf '%s\n' "$body" | sed -E \
            -e '/^\*\*(TL;DR|Status|Date|Read if)\*\*/d' -e '/^---$/d')"
        body="$(printf '%s\n' "$body" | sed -E '1{ /^# '"$(sed 's/[.[\/*^$]/\\&/g' <<< "$title")"'$/d; }')"
    elif [[ "$method" == "frontmatter" ]]; then
        # Strip YAML frontmatter block (between first and second ---)
        body="$(printf '%s\n' "$body" | awk 'BEGIN{s=0} /^---$/{s++;next} s>=2{print}')"
    fi
    body="$(printf '%s\n' "$body" | sed '/./,$!d')"
    { _mig_generate_frontmatter "$title" "$id" "$status" "$type" "$domain" \
          "$summary" "$created" "$updated" "$tags"; printf '\n%s\n' "$body"; } > "$out"
}

_mig_extract_sections() {
    awk '/^## (Context|Key Findings|Decision Log|Artifacts|Summary|TL;DR)/{p=1;print;next}
         /^## /{p=0;next} /^# /{p=0;next} p{print}' "$1"
}

_mig_execute() {
    local source_dir="$1" vault_root="$2" plan_file="$3"
    local staging
    staging="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$staging'" EXIT INT TERM
    local -a log_lines=()
    local compact_project_list=""
    local processed=0

    # Collect compact project directories without relying on bash 4 associative arrays.
    local -a compact_projects=()
    while IFS=$'\t' read -r action _ _ _ _ _ _ _ _ _ _ _ proj _; do
        [[ "$action" != "compact" ]] && continue
        case "$compact_project_list" in
            *$'\n'"$proj"$'\n'*) ;;
            *)
                compact_project_list+=$'\n'"$proj"$'\n'
                compact_projects+=("$proj")
                ;;
        esac
    done < "$plan_file"

    # Process non-compact plan lines
    while IFS=$'\t' read -r action rel_path tier tid title status type domain summary created updated tags _ notes; do
        local src_file="${source_dir}/${rel_path}"
        case "$action" in
        migrate)
            local method="h1"
            if _mig_has_frontmatter "$src_file"; then method="frontmatter"
            elif head -20 "$src_file" 2>/dev/null | grep -qiE '\*\*(TL;DR|Status)\*\*'; then method="informal"; fi
            mkdir -p "${staging}/${tier}"
            _mig_transform_file "$src_file" "${staging}/${tier}/${tid}.md" \
                "$title" "$tid" "$status" "$type" "$domain" "$summary" \
                "$created" "$updated" "$tags" "$method"
            _created "$rel_path -> $tier/$tid.md"
            log_lines+=("| $rel_path | migrate | $tier/$tid.md | ${method} headers converted |")
            processed=$((processed + 1)) ;;
        archive)
            mkdir -p "${staging}/archive"
            cp "$src_file" "${staging}/archive/$(basename "$rel_path")"
            _moved "$rel_path -> archive/$(basename "$rel_path")"
            log_lines+=("| $rel_path | archive | archive/$(basename "$rel_path") | session file |")
            processed=$((processed + 1)) ;;
        skip)
            _skip "$rel_path${notes:+ - $notes}"
            log_lines+=("| $rel_path | skip | - | ${notes:-} |")
            processed=$((processed + 1)) ;;
        esac
    done < "$plan_file"

    # Process compact groups
    local proj_name
    if [[ "${#compact_projects[@]}" -gt 0 ]]; then
        for proj_name in "${compact_projects[@]}"; do
            local file_list="" proj_dir="${source_dir}/${proj_name}"
            while IFS=$'\t' read -r action rel_path _ _ _ _ _ _ _ _ _ _ proj _; do
                [[ "$action" == "compact" && "$proj" == "$proj_name" ]] || continue
                file_list+="${rel_path}"$'\n'
            done < "$plan_file"

        # Find master: QUICK-CONTEXT > README > first file
            local master=""
            for candidate in QUICK-CONTEXT.md README.md; do
                [[ -f "${proj_dir}/${candidate}" ]] && master="${proj_name}/${candidate}" && break
            done
            [[ -z "$master" ]] && master="$(printf '%s' "$file_list" | head -1)"
            # Get metadata from first compact entry
            local c_tier="" c_tid="" c_title="" c_status="" c_type="" c_domain=""
            local c_summary="" c_created="" c_updated="" c_tags=""
            while IFS=$'\t' read -r action _ tier tid title status type domain summary created updated tags proj _; do
                [[ "$action" == "compact" && "$proj" == "$proj_name" ]] || continue
                c_tier="$tier"; c_title="$title"; c_status="$status"
                c_type="$type"; c_domain="$domain"; c_summary="$summary"
                c_created="$created"; c_updated="$updated"; c_tags="$tags"; break
            done < "$plan_file"
            # Use project folder name as the entry ID, not individual file titles
            c_tid="$(_mig_title_to_id "$proj_name")"
            c_title="$proj_name"
            # Build compacted content: sections + ToC
            local sections="" toc=""
            if [[ -n "$master" ]]; then
                local ms
                ms="$(_mig_extract_sections "${source_dir}/${master}")"
                [[ -n "$ms" ]] && sections="### From: $(basename "$master")"$'\n\n'"${ms}"$'\n\n'
            fi
            while IFS= read -r rel_f; do
                [[ -z "$rel_f" ]] && continue
                local bname
                bname="$(basename "$rel_f")"
                _mig_is_index_file "$bname" && continue
                local extracted
                extracted="$(_mig_extract_sections "${source_dir}/${rel_f}")"
                if [[ -n "$extracted" ]]; then
                    sections+="### From: ${bname}"$'\n\n'"${extracted}"$'\n\n'
                else
                    toc+="- ${bname}"$'\n'
                fi
            done <<< "$file_list"
            local body=""
            [[ -n "$toc" ]] && body="## Table of Contents"$'\n\n'"${toc}"$'\n'
            [[ -n "$sections" ]] && body+="${sections}"
            # Write compacted entry + archive originals
            mkdir -p "${staging}/${c_tier}" "${staging}/archive/${proj_name}"
            { _mig_generate_frontmatter "$c_title" "$c_tid" "$c_status" "$c_type" \
                  "$c_domain" "$c_summary" "$c_created" "$c_updated" "$c_tags"
              printf '\n%s\n' "$body"; } > "${staging}/${c_tier}/${c_tid}.md"
            for orig in "${proj_dir}"/*; do
                [[ -f "$orig" ]] && cp "$orig" "${staging}/archive/${proj_name}/"
            done
            _created "$proj_name/ -> $c_tier/$c_tid.md (compacted)"
            _moved   "$proj_name/ -> archive/$proj_name/ (originals)"
            log_lines+=("| $proj_name/ | compact | $c_tier/$c_tid.md | project compacted |")
            processed=$((processed + 1))
        done
    fi

    # Move staging into vault
    for tier_dir in "${staging}"/*; do
        [[ -d "$tier_dir" ]] || continue
        local tier_name
        tier_name="$(basename "$tier_dir")"
        mkdir -p "${vault_root}/${tier_name}"
        for entry in "${tier_dir}"/*; do
            [[ -e "$entry" ]] || continue
            if [[ -d "$entry" ]]; then cp -R "$entry" "${vault_root}/${tier_name}/"
            else mv "$entry" "${vault_root}/${tier_name}/"; fi
        done
    done

    # Write migration log
    local today
    today="$(date '+%Y-%m-%d')"
    { printf '# Migration Log\n> Generated by kb migrate on %s\n> Source: %s\n\n' "$today" "$source_dir"
      printf '| Original Path | Action | Vault Path | Notes |\n'
      printf '|---------------|--------|------------|-------|\n'
      if [[ "${#log_lines[@]}" -gt 0 ]]; then
          for row in "${log_lines[@]}"; do printf '%s\n' "$row"; done
      fi
    } > "${vault_root}/MIGRATION-LOG.md"

    # shellcheck source=/dev/null
    source "${KB_ROOT}/lib/index.sh" && kb_index
    _ok "Migration complete. ${processed} files processed."
    rm -rf "$staging"
}
