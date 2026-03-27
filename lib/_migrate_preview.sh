#!/usr/bin/env bash
# lib/_migrate_preview.sh - Phase 2: display migration plan and get confirmation
# Sourced by migrate.sh. Depends on _theme.sh.

_mig_preview() {
    local source_dir="$1" plan_file="$2" counts_line="$3"
    local total migrate compact archive skip warnings
    IFS=$'\t' read -r total migrate compact archive skip warnings <<< "$counts_line"

    _info "Source directory will remain UNTOUCHED. Files will be copied."
    printf '\n   SOURCE: %s (%s files)\n' "$source_dir" "$total"

    _header "Summary ========================================"
    _created "Migrate:  $migrate standalone files"
    _created "Compact:  $compact project entries"
    _moved   "Archive:  $archive session files"
    _skip    "Skip:     $skip files"
    _warn    "Warnings: $warnings (no metadata / heuristic)"

    # Warnings section
    local has_warns=""
    while IFS=$'\t' read -r action rel_path _ _ _ _ _ _ _ _ _ _ _ notes; do
        if [[ "$action" == "skip" || "$action" == "warn" ]]; then
            [[ -z "$has_warns" ]] && _header "Warnings ======================================="
            has_warns=1
            _warn "$rel_path${notes:+ - $notes}"
        fi
    done < "$plan_file"

    # Standalone section
    if [[ "$migrate" -gt 0 ]]; then
        _header "Standalone ($migrate) ================================"
        while IFS=$'\t' read -r action rel_path tier tid title status type _ _ created _ _ _ _; do
            [[ "$action" != "migrate" ]] && continue
            _created "$rel_path -> $tier/$tid.md"
            _detail  "$status | $type | $created"
        done < "$plan_file"
    fi

    # Projects section - group compact entries by project_dir
    if [[ "$compact" -gt 0 ]]; then
        _header "Projects ($compact) ==================================="
        local prev_proj=""
        while IFS=$'\t' read -r action rel_path tier tid _ _ _ _ _ _ _ _ proj _; do
            [[ "$action" != "compact" ]] && continue
            if [[ "$proj" != "$prev_proj" ]]; then
                prev_proj="$proj"
                _created "$proj/ -> $tier/$tid.md"
                _moved   "archive/$proj/ (originals)"
            fi
            _detail  "$rel_path"
        done < <(sort -t$'\t' -k13,13 "$plan_file")
    fi
    printf '\n'
}

_mig_confirm() {
    local dry_run="$1" yes_flag="$2" vault_root="$3" plan_file="$4"

    # Write plan as JSON
    local json_out="$vault_root/.kb/migrate-plan.json"
    mkdir -p "$vault_root/.kb"
    {
        printf '[\n'
        local first=1
        while IFS=$'\t' read -r action rel_path tier tid title status type domain summary created updated tags proj notes; do
            [[ "$first" -eq 1 ]] && first=0 || printf ',\n'
            # Escape double quotes in string fields
            title="${title//\"/\\\"}"
            summary="${summary//\"/\\\"}"
            notes="${notes//\"/\\\"}"
            printf '  {"action":"%s","path":"%s","tier":"%s","id":"%s","title":"%s","status":"%s","type":"%s","domain":"%s","summary":"%s","created":"%s","updated":"%s","tags":"%s","project":"%s","notes":"%s"}' \
                "$action" "$rel_path" "$tier" "$tid" "$title" "$status" "$type" "$domain" "$summary" "$created" "$updated" "$tags" "$proj" "$notes"
        done < "$plan_file"
        printf '\n]\n'
    } > "$json_out"

    if [[ "$dry_run" == "true" ]]; then
        _info "Dry run complete. Plan saved to $json_out"
        return 1
    fi

    _ok "Plan saved to $json_out"

    if [[ "$yes_flag" == "true" ]]; then
        return 0
    fi

    printf '%s>>%s  Proceed? [y/N] ' "$_c_cyan" "$_c_reset"
    local answer
    read -r answer < /dev/tty
    [[ "$answer" =~ ^[yY]$ ]]
}
