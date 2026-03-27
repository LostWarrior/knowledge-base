#!/usr/bin/env bash
# lib/_migrate_utils.sh - Shared utilities for kb migrate
# Sourced by other _migrate_*.sh modules. All functions prefixed _mig_.

_mig_validate_path() {
    if [[ "$1" == *".."* ]]; then
        printf 'Error: path traversal ("..") not allowed: %s\n' "$1" >&2
        return 1
    fi
}

_mig_title_to_id() {
    local id
    id="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | tr -s '-')"
    id="${id#-}"; id="${id%-}"
    id="$(printf '%s' "$id" | cut -c1-50)"
    id="${id%-}"
    printf '%s' "$id"
}

_mig_normalize_status() {
    local raw
    raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
        active|"in progress"|"in-progress") printf 'active' ;;
        archived|historical|obsolete)       printf 'archived' ;;
        complete|done|stable|reference)     printf 'reference' ;;
        *)                                  printf 'reference' ;;
    esac
}

_mig_status_to_tier() {
    case "$1" in
        active)    printf 'active' ;;
        reference) printf 'reference' ;;
        archived)  printf 'archive' ;;
        *)         printf 'reference' ;;
    esac
}

_mig_id_exists() {
    local id="$1" vault="$2"
    for tier in active reference archive learning tooling; do
        [[ -f "$vault/$tier/$id.md" ]] && return 0
    done
    return 1
}

_mig_is_index_file() {
    local lower
    lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        readme.md|quick-context.md|master-index.md|claude.md|index.md) return 0 ;;
        *) return 1 ;;
    esac
}

_mig_is_session_file() {
    local b="$1"
    [[ "$b" =~ ^SESSION-.*\.md$ ]] && return 0
    [[ "$b" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-.*\.md$ ]] && return 0
    return 1
}

_mig_is_project_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    local md_count has_index=false
    md_count="$(find "$dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$md_count" -ge 2 ]] || return 1
    local f
    for f in "$dir"/*.md; do
        _mig_is_index_file "$(basename "$f")" && has_index=true && break
    done
    [[ "$has_index" == "true" ]]
}

_mig_date_from_filename() {
    local match
    match="$(printf '%s' "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)"
    printf '%s' "${match:-}"
}

_mig_file_mdate() {
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f '%Sm' -t '%Y-%m-%d' "$1" 2>/dev/null || true
    else
        date -r "$1" '+%Y-%m-%d' 2>/dev/null || stat -c '%y' "$1" 2>/dev/null | cut -d' ' -f1 || true
    fi
}

_mig_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

_mig_extract_tags() {
    local tmpfile
    tmpfile="$(mktemp)"
    grep -v '^##' "$1" 2>/dev/null | grep -oE '#[a-zA-Z][a-zA-Z0-9_-]*' | sed 's/^#//' > "$tmpfile" 2>/dev/null || true
    sort -u "$tmpfile" | tr '\n' ',' | sed 's/,$//' || true
    rm -f "$tmpfile"
}
