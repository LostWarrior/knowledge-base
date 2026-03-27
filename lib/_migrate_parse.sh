#!/usr/bin/env bash
# lib/_migrate_parse.sh - Metadata parser chain for kb migrate
# Sourced by _migrate_scan.sh. Depends on _migrate_utils.sh.

_mig_has_frontmatter() {
    local first
    first="$(head -1 "$1" 2>/dev/null || true)"
    [[ "$first" == "---" ]]
}

_mig_fm_field() {
    local field="$1" file="$2" val
    val="$(sed -n '/^---$/,/^---$/{ /^'"$field"':/{ s/^'"$field"':[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//; p; q; }; }' "$file" 2>/dev/null || true)"
    printf '%s' "$val"
}

_mig_parse_informal() {
    local file="$1" line key val title="" count=0
    while IFS= read -r line && [[ "$count" -lt 30 ]]; do
        count=$((count + 1))
        # First H1 heading -> title
        if [[ -z "$title" && "$line" =~ ^#\ (.+) ]]; then
            title="${BASH_REMATCH[1]}"
            printf 'title=%s\n' "$title"
            continue
        fi
        # Bold key-value: **Key**: value or **Key:** value
        if [[ "$line" =~ ^\*\*([^*]+)\*\*:?[[:space:]]*(.*) ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            # Strip trailing colon from key if present
            key="${key%:}"
            # Lowercase key for matching
            local lk
            lk="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
            case "$lk" in
                "tl;dr"|tldr|summary) printf 'summary=%s\n' "$val" ;;
                date)                 printf 'date=%s\n' "$val" ;;
                status)               printf 'status=%s\n' "$val" ;;
                "read if"|readif)     printf 'readif=%s\n' "$val" ;;
            esac
        fi
    done < "$file"
}

_mig_guess_type() {
    local lower
    lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        *session*|SESSION-*) printf 'session' ;;
        *analysis*)          printf 'analysis' ;;
        *guide*|*how-to*)    printf 'guide' ;;
        *runbook*)           printf 'runbook' ;;
        *report*)            printf 'report' ;;
        *)                   printf 'analysis' ;;
    esac
}

_mig_parse_file() {
    local filepath="$1"
    local fname title="" status="" type="" domain="" summary="" created="" updated="" tags="" method=""

    fname="$(basename "$filepath")"

    # --- Strategy A: YAML frontmatter ---
    if _mig_has_frontmatter "$filepath"; then
        method="frontmatter"
        title="$(_mig_fm_field title "$filepath")"
        status="$(_mig_fm_field status "$filepath")"
        type="$(_mig_fm_field type "$filepath")"
        domain="$(_mig_fm_field domain "$filepath")"
        summary="$(_mig_fm_field summary "$filepath")"
        created="$(_mig_fm_field created "$filepath")"
        updated="$(_mig_fm_field updated "$filepath")"
        tags="$(_mig_fm_field tags "$filepath")"
    fi

    # --- Strategy B: Informal bold headers ---
    if [[ -z "$method" ]]; then
        local probe
        probe="$(head -20 "$filepath" 2>/dev/null | grep -iE '\*\*(TL;DR|Status)\*\*' || true)"
        if [[ -n "$probe" ]]; then
            method="informal"
            local tmpf
            tmpf="$(mktemp)"
            trap 'rm -f "$tmpf"' RETURN
            _mig_parse_informal "$filepath" > "$tmpf"
            title="$(grep '^title=' "$tmpf" | head -1 | cut -d= -f2- || true)"
            summary="$(grep '^summary=' "$tmpf" | head -1 | cut -d= -f2- || true)"
            created="$(grep '^date=' "$tmpf" | head -1 | cut -d= -f2- || true)"
            status="$(grep '^status=' "$tmpf" | head -1 | cut -d= -f2- || true)"
            rm -f "$tmpf"
            trap - RETURN
        fi
    fi

    # --- Strategy C: H1 heuristic ---
    if [[ -z "$method" ]]; then
        local h1
        h1="$(grep -m1 '^# ' "$filepath" 2>/dev/null | sed 's/^# //' || true)"
        if [[ -n "$h1" ]]; then
            method="h1"
            title="$h1"
        fi
    fi

    # --- Strategy D: Filename fallback ---
    if [[ -z "$method" ]]; then
        method="filename"
    fi

    # --- Fill defaults for missing fields ---
    if [[ -z "$title" ]]; then
        title="${fname%.md}"
        title="${title//-/ }"
    fi
    status="$(_mig_normalize_status "${status:-reference}")"
    if [[ -z "$type" ]]; then
        type="$(_mig_guess_type "$fname")"
    fi
    domain="${domain:-general}"
    summary="${summary:-$title}"
    if [[ -z "$created" ]]; then
        created="$(_mig_date_from_filename "$fname")"
        if [[ -z "$created" ]]; then
            created="$(_mig_file_mdate "$filepath")"
        fi
    fi
    updated="${updated:-$(_mig_file_mdate "$filepath")}"
    if [[ -z "$tags" ]]; then
        tags="$(_mig_extract_tags "$filepath")"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$title" "$status" "$type" "$domain" "$summary" "$created" "$updated" "$tags" "$method"
}
