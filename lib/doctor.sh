#!/usr/bin/env bash
# lib/doctor.sh - Comprehensive health check for the kb vault
# Requires: VAULT_ROOT, KB_ROOT (set by dispatcher)

# All expected tier directories
readonly DOCTOR_TIERS=(active reference learning tooling archive)

# ANSI color codes (only used when terminal supports them)
_doctor_color_reset=""
_doctor_color_pass=""
_doctor_color_fail=""
_doctor_color_warn=""

if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    _doctor_color_reset=$'\033[0m'
    _doctor_color_pass=$'\033[1;32m'
    _doctor_color_fail=$'\033[1;31m'
    _doctor_color_warn=$'\033[1;33m'
fi

# ---------------------------------------------------------------------------
# _doctor_pass <message>
# _doctor_fail <message>
# _doctor_warn <message>
#   Print a check result with colored status indicator.
# ---------------------------------------------------------------------------
_doctor_pass() {
    printf '  %sPASS%s  %s\n' "$_doctor_color_pass" "$_doctor_color_reset" "$1"
}
_doctor_fail() {
    printf '  %sFAIL%s  %s\n' "$_doctor_color_fail" "$_doctor_color_reset" "$1"
}
_doctor_warn() {
    printf '  %sWARN%s  %s\n' "$_doctor_color_warn" "$_doctor_color_reset" "$1"
}

# ---------------------------------------------------------------------------
# _doctor_check_structure
#   Verifies all expected tier directories and config files exist.
#   Returns number of failures.
# ---------------------------------------------------------------------------
_doctor_check_structure() {
    local failures=0

    printf '\n[1/6] Vault Structure\n'

    # Check tier directories
    local tier
    for tier in "${DOCTOR_TIERS[@]}"; do
        local tier_dir="${VAULT_ROOT}/${tier}"
        if [[ -d "$tier_dir" ]]; then
            _doctor_pass "Tier directory: ${tier}/"
        else
            _doctor_fail "Missing tier directory: ${tier}/"
            failures=$((failures + 1))
        fi
    done

    # Check .kb directory and config
    local kb_config_dir="${VAULT_ROOT}/.kb"
    if [[ -d "$kb_config_dir" ]]; then
        _doctor_pass "Config directory: .kb/"
    else
        _doctor_fail "Missing config directory: .kb/"
        failures=$((failures + 1))
    fi

    local kb_yaml="${VAULT_ROOT}/.kb/kb.yaml"
    if [[ -f "$kb_yaml" ]]; then
        _doctor_pass "Config file: .kb/kb.yaml"
    else
        _doctor_fail "Missing config file: .kb/kb.yaml"
        failures=$((failures + 1))
    fi

    printf '%d\n' "$failures"
}

# ---------------------------------------------------------------------------
# _doctor_check_validate
#   Runs kb_validate and captures results.
#   Returns number of errors found.
# ---------------------------------------------------------------------------
_doctor_check_validate() {
    printf '\n[2/6] Frontmatter Validation\n'

    local errors=0
    local warnings=0

    if [[ -f "${KB_ROOT:-}/lib/validate.sh" ]]; then
        local output
        # Source and run validation in quiet mode
        output="$(source "${KB_ROOT}/lib/validate.sh" && kb_validate --quiet 2>&1)" || true

        # Parse summary line for counts
        if [[ "$output" =~ ([0-9]+)\ errors ]]; then
            errors="${BASH_REMATCH[1]}"
        fi
        if [[ "$output" =~ ([0-9]+)\ warnings ]]; then
            warnings="${BASH_REMATCH[1]}"
        fi

        if [[ "$errors" -eq 0 ]] && [[ "$warnings" -eq 0 ]]; then
            _doctor_pass "All entries have valid frontmatter"
        elif [[ "$errors" -eq 0 ]]; then
            _doctor_warn "${warnings} validation warning(s)"
            printf "         Run 'kb validate' for details.\n"
        else
            _doctor_fail "${errors} validation error(s), ${warnings} warning(s)"
            printf "         Run 'kb validate' for details.\n"
        fi
    else
        _doctor_warn "validate.sh not found at ${KB_ROOT:-<unset>}/lib/validate.sh"
        printf "         Cannot run frontmatter validation.\n"
    fi

    printf '%d\n' "$errors"
}

# ---------------------------------------------------------------------------
# _doctor_check_stale
#   Runs stale check and reports count.
#   Returns number of stale entries.
# ---------------------------------------------------------------------------
_doctor_check_stale() {
    printf '\n[3/6] TTL / Stale Entries\n'

    local stale_count=0

    if [[ -f "${KB_ROOT:-}/lib/stale.sh" ]]; then
        local output
        output="$(source "${KB_ROOT}/lib/stale.sh" && kb_stale 2>&1)" || true

        if [[ "$output" =~ Found\ ([0-9]+)\ stale ]]; then
            stale_count="${BASH_REMATCH[1]}"
        fi

        if [[ "$stale_count" -eq 0 ]]; then
            _doctor_pass "No stale entries"
        else
            _doctor_warn "${stale_count} entry/entries past TTL"
            printf "         Run 'kb stale' for the full list.\n"
        fi
    else
        _doctor_warn "stale.sh not found at ${KB_ROOT:-<unset>}/lib/stale.sh"
        printf "         Cannot run TTL check.\n"
    fi

    printf '%d\n' "$stale_count"
}

# ---------------------------------------------------------------------------
# _doctor_check_index
#   Checks INDEX.md exists and is not older than the newest entry.
#   Returns 0 if fresh, 1 if stale or missing.
# ---------------------------------------------------------------------------
_doctor_check_index() {
    printf '\n[4/6] INDEX.md Freshness\n'

    local index_file="${VAULT_ROOT}/INDEX.md"
    local result=0

    if [[ ! -f "$index_file" ]]; then
        _doctor_fail "INDEX.md not found in vault root"
        printf "         Run 'kb index' to generate it.\n"
        printf '1\n'
        return
    fi

    # Get INDEX.md modification time
    local index_mtime
    index_mtime="$(stat -f '%m' "$index_file" 2>/dev/null || stat -c '%Y' "$index_file" 2>/dev/null)"

    # Find newest .md file across tiers
    local newest_mtime=0
    local newest_file=""
    local tier
    for tier in "${DOCTOR_TIERS[@]}"; do
        local tier_dir="${VAULT_ROOT}/${tier}"
        [[ -d "$tier_dir" ]] || continue
        while IFS= read -r -d '' f; do
            local fmtime
            fmtime="$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null)"
            if [[ -n "$fmtime" ]] && [[ "$fmtime" -gt "$newest_mtime" ]]; then
                newest_mtime="$fmtime"
                newest_file="${f#"${VAULT_ROOT}/"}"
            fi
        done < <(find "$tier_dir" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)
    done

    if [[ -n "$index_mtime" ]] && [[ "$newest_mtime" -gt 0 ]]; then
        if [[ "$index_mtime" -ge "$newest_mtime" ]]; then
            _doctor_pass "INDEX.md is up to date"
        else
            _doctor_warn "INDEX.md is stale (newest entry: ${newest_file})"
            printf "         Run 'kb index' to rebuild.\n"
            result=1
        fi
    else
        _doctor_pass "INDEX.md exists (no entries to compare against)"
    fi

    printf '%d\n' "$result"
}

# ---------------------------------------------------------------------------
# _doctor_check_orphans
#   Finds non-.md files in tier directories that shouldn't be there.
#   Returns count of orphaned files.
# ---------------------------------------------------------------------------
_doctor_check_orphans() {
    printf '\n[5/6] Orphan Files\n'

    local orphan_count=0

    local tier
    for tier in "${DOCTOR_TIERS[@]}"; do
        local tier_dir="${VAULT_ROOT}/${tier}"
        [[ -d "$tier_dir" ]] || continue

        while IFS= read -r -d '' file; do
            local filename
            filename="$(basename "$file")"
            # Skip hidden files (like .gitkeep)
            if [[ "$filename" == .* ]]; then
                continue
            fi
            _doctor_warn "Orphan file: ${tier}/${filename}"
            orphan_count=$((orphan_count + 1))
        done < <(find "$tier_dir" -maxdepth 1 -type f ! -name '*.md' -print0 2>/dev/null)
    done

    if [[ "$orphan_count" -eq 0 ]]; then
        _doctor_pass "No orphan files in tier directories"
    else
        printf "         Move non-.md files out of tier directories.\n"
    fi

    printf '%d\n' "$orphan_count"
}

# ---------------------------------------------------------------------------
# _doctor_check_security
#   Security checks:
#   - No files with executable bit set in vault
#   - No symlinks pointing outside the vault
#   Returns count of issues found.
# ---------------------------------------------------------------------------
_doctor_check_security() {
    printf '\n[6/6] Security\n'

    local issues=0

    # Check for executable files in tier directories
    local tier
    for tier in "${DOCTOR_TIERS[@]}"; do
        local tier_dir="${VAULT_ROOT}/${tier}"
        [[ -d "$tier_dir" ]] || continue

        while IFS= read -r -d '' file; do
            local rel="${file#"${VAULT_ROOT}/"}"
            _doctor_fail "Executable bit set: ${rel}"
            printf "         Fix: chmod -x '%s'\n" "$file"
            issues=$((issues + 1))
        done < <(find "$tier_dir" -maxdepth 1 -type f -perm +0111 -print0 2>/dev/null)
    done

    if [[ "$issues" -eq 0 ]]; then
        _doctor_pass "No executable files in vault"
    fi

    # Check for symlinks pointing outside the vault
    local symlink_issues=0
    while IFS= read -r -d '' link; do
        local target
        # Resolve the symlink target to an absolute path
        target="$(cd "$(dirname "$link")" && /bin/pwd -P)/$(readlink "$link")"
        # Normalize: resolve to real path if possible
        if command -v realpath >/dev/null 2>&1; then
            target="$(realpath "$target" 2>/dev/null || printf '%s' "$target")"
        fi

        local vault_real
        if command -v realpath >/dev/null 2>&1; then
            vault_real="$(realpath "$VAULT_ROOT" 2>/dev/null || printf '%s' "$VAULT_ROOT")"
        else
            vault_real="$VAULT_ROOT"
        fi

        # Check if target is within vault
        if [[ "$target" != "${vault_real}"* ]]; then
            local rel="${link#"${VAULT_ROOT}/"}"
            _doctor_fail "Symlink escapes vault: ${rel} -> ${target}"
            symlink_issues=$((symlink_issues + 1))
            issues=$((issues + 1))
        fi
    done < <(find "$VAULT_ROOT" -type l -print0 2>/dev/null)

    if [[ "$symlink_issues" -eq 0 ]]; then
        _doctor_pass "No symlinks pointing outside vault"
    fi

    printf '%d\n' "$issues"
}

# ---------------------------------------------------------------------------
# kb_doctor
#   Runs all health checks and produces a summary report.
# ---------------------------------------------------------------------------
kb_doctor() {
    if [[ -z "${VAULT_ROOT:-}" ]]; then
        printf 'Error: VAULT_ROOT is not set\n' >&2
        return 1
    fi

    printf '\n=== kb doctor ===\n'
    printf 'Vault: %s\n' "$VAULT_ROOT"

    # Run each check and capture its failure/issue count from the last line
    local structure_result validate_result stale_result index_result orphan_result security_result
    local output

    output="$(_doctor_check_structure)"
    # Print all lines except the last (the count), then capture the count
    printf '%s\n' "$output" | sed '$d'
    structure_result="$(printf '%s\n' "$output" | tail -n 1)"

    output="$(_doctor_check_validate)"
    printf '%s\n' "$output" | sed '$d'
    validate_result="$(printf '%s\n' "$output" | tail -n 1)"

    output="$(_doctor_check_stale)"
    printf '%s\n' "$output" | sed '$d'
    stale_result="$(printf '%s\n' "$output" | tail -n 1)"

    output="$(_doctor_check_index)"
    printf '%s\n' "$output" | sed '$d'
    index_result="$(printf '%s\n' "$output" | tail -n 1)"

    output="$(_doctor_check_orphans)"
    printf '%s\n' "$output" | sed '$d'
    orphan_result="$(printf '%s\n' "$output" | tail -n 1)"

    output="$(_doctor_check_security)"
    printf '%s\n' "$output" | sed '$d'
    security_result="$(printf '%s\n' "$output" | tail -n 1)"

    # ------------------------------------------------------------------
    # Overall assessment
    # ------------------------------------------------------------------
    local total_errors=$((structure_result + validate_result + security_result))
    local total_warnings=$((stale_result + index_result + orphan_result))

    printf '\n=== Summary ===\n\n'

    if [[ "$total_errors" -gt 0 ]]; then
        printf '  Status: %sERRORS%s (%d error(s), %d warning(s))\n' \
            "$_doctor_color_fail" "$_doctor_color_reset" "$total_errors" "$total_warnings"
    elif [[ "$total_warnings" -gt 0 ]]; then
        printf '  Status: %sWARNINGS%s (%d warning(s))\n' \
            "$_doctor_color_warn" "$_doctor_color_reset" "$total_warnings"
    else
        printf '  Status: %sHEALTHY%s\n' \
            "$_doctor_color_pass" "$_doctor_color_reset"
    fi

    printf '\n'

    # Provide actionable suggestions
    if [[ "$total_errors" -gt 0 ]] || [[ "$total_warnings" -gt 0 ]]; then
        printf '  Suggested actions:\n'
        if [[ "$structure_result" -gt 0 ]]; then
            printf "    - Run 'kb init' to create missing vault structure\n"
        fi
        if [[ "$validate_result" -gt 0 ]]; then
            printf "    - Run 'kb validate' and fix frontmatter errors\n"
        fi
        if [[ "$stale_result" -gt 0 ]]; then
            printf "    - Run 'kb stale' and archive or update old entries\n"
        fi
        if [[ "$index_result" -gt 0 ]]; then
            printf "    - Run 'kb index' to rebuild INDEX.md\n"
        fi
        if [[ "$orphan_result" -gt 0 ]]; then
            printf "    - Remove or relocate non-.md files from tier directories\n"
        fi
        if [[ "$security_result" -gt 0 ]]; then
            printf "    - Fix file permissions and remove external symlinks\n"
        fi
        printf '\n'
    fi

    if [[ "$total_errors" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Allow direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    kb_doctor "$@"
fi
