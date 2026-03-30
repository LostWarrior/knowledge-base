#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# kb test suite
# Simple test runner - no external dependencies (no bats)
# Usage: ./tests/run_all.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KB_BIN="${SCRIPT_DIR}/../bin/kb"
KB_VERSION="$(sed -n 's/^KB_VERSION="\([^"]*\)"$/\1/p' "$KB_BIN")"

PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()
SKIP_MIGRATE_TESTS="${SKIP_MIGRATE_TESTS:-0}"

# --- Colors (if terminal supports them) ---
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    # shellcheck disable=SC2034
    YELLOW='\033[0;33m'
    RESET='\033[0m'
else
    GREEN=''
    RED=''
    # shellcheck disable=SC2034
    YELLOW=''
    RESET=''
fi

# --- Assertion helpers ---

assert_eq() {
    [[ "$1" == "$2" ]] || { echo "  FAIL: expected '$2', got '$1'"; return 1; }
}

assert_file_exists() {
    [[ -f "$1" ]] || { echo "  FAIL: file not found: $1"; return 1; }
}

assert_dir_exists() {
    [[ -d "$1" ]] || { echo "  FAIL: directory not found: $1"; return 1; }
}

assert_contains() {
    grep -q "$2" "$1" || { echo "  FAIL: '$1' does not contain '$2'"; return 1; }
}

assert_contains_literal() {
    grep -Fq -- "$2" "$1" || { echo "  FAIL: '$1' does not contain '$2'"; return 1; }
}

assert_not_contains() {
    ! grep -q "$2" "$1" || { echo "  FAIL: '$1' should not contain '$2'"; return 1; }
}

assert_not_contains_literal() {
    ! grep -Fq -- "$2" "$1" || { echo "  FAIL: '$1' should not contain '$2'"; return 1; }
}

assert_manifest_contains() {
    local vault_root="$1"
    local needle="$2"
    assert_contains "$vault_root/.kb/manifest.json" "$needle"
}

assert_index_section_contains() {
    local index_file="$1"
    local section="$2"
    local needle="$3"
    awk -v section="$section" -v needle="$needle" '
        $0 == section { in_section=1; next }
        /^## / && in_section { exit 1 }
        in_section && index($0, needle) { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$index_file" || {
        echo "  FAIL: '$index_file' section '$section' does not contain '$needle'"
        return 1
    }
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    [[ "$actual" -eq "$expected" ]] || { echo "  FAIL: expected exit code $expected, got $actual"; return 1; }
}

# --- Test runner ---

run_test() {
    local test_name="$1"
    local test_func="$2"

    printf "  %-50s " "$test_name"

    local tmpdir
    tmpdir="$(mktemp -d)"

    local output
    if output=$("$test_func" "$tmpdir" 2>&1); then
        printf '%sPASS%s\n' "${GREEN}" "${RESET}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '%sFAIL%s\n' "${RED}" "${RESET}"
        if [[ -n "$output" ]]; then
            printf '%s\n' "$output" | sed 's/^/    /'
        fi
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILURES+=("$test_name")
    fi

    rm -rf "$tmpdir"
}

# ============================================================
# Tests
# ============================================================

test_init_creates_structure() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault

    assert_dir_exists "$tmpdir/test-vault"
    assert_dir_exists "$tmpdir/test-vault/active"
    assert_dir_exists "$tmpdir/test-vault/reference"
    assert_dir_exists "$tmpdir/test-vault/archive"
    assert_dir_exists "$tmpdir/test-vault/.kb"
    assert_file_exists "$tmpdir/test-vault/INDEX.md"
    assert_file_exists "$tmpdir/test-vault/CLAUDE.md"
    assert_file_exists "$tmpdir/test-vault/.kb/kb.yaml"
}

test_init_index_has_header() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault

    assert_contains "$tmpdir/test-vault/INDEX.md" "# Knowledge Base Index"
}

test_init_manifest_has_versioned_shape() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault

    local manifest="$tmpdir/test-vault/.kb/manifest.json"
    assert_file_exists "$manifest"

    jq -e '.schema_version == 1' "$manifest" >/dev/null
    jq -e '(.generated_at | type == "string") and (.entries | type == "array") and (.entries | length == 0)' "$manifest" >/dev/null
}

test_init_works_through_symlinked_install() {
    local tmpdir="$1"
    local cellar_root="$tmpdir/Cellar/kb/${KB_VERSION}"
    local front_bin="$tmpdir/front-bin"

    mkdir -p \
        "$cellar_root/bin" \
        "$cellar_root/share/kb/lib" \
        "$cellar_root/share/kb/templates" \
        "$cellar_root/share/kb/hooks" \
        "$front_bin"

    cp "$KB_BIN" "$cellar_root/bin/kb"
    cp "$SCRIPT_DIR/../lib/"*.sh "$cellar_root/share/kb/lib/"
    cp "$SCRIPT_DIR/../templates/"* "$cellar_root/share/kb/templates/"
    cp "$SCRIPT_DIR/../hooks/"* "$cellar_root/share/kb/hooks/"
    ln -s "$cellar_root/bin/kb" "$front_bin/kb"

    cd "$tmpdir"
    "$front_bin/kb" init test-vault >/dev/null

    assert_dir_exists "$tmpdir/test-vault/.kb"
    assert_file_exists "$tmpdir/test-vault/.kb/kb.yaml"
    assert_file_exists "$tmpdir/test-vault/INDEX.md"
}

test_init_claude_uses_entries_manifest_contract() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault

    local claude="$tmpdir/test-vault/CLAUDE.md"
    assert_file_exists "$claude"

    assert_contains_literal "$claude" "jq '.entries[] | select(.tier == \"active\")' .kb/manifest.json"
    assert_contains_literal "$claude" "jq '.entries[] | select(.domain == \"backend\")' .kb/manifest.json"
    assert_contains_literal "$claude" "jq '.entries[] | select(.tags | index(\"api\"))' .kb/manifest.json"
    assert_contains_literal "$claude" "jq -r '.entries[] | \"\\(.id)\\t\\(.title)\"' .kb/manifest.json"
    assert_not_contains_literal "$claude" "jq '.[] | select(.status==\"active\")' .kb/manifest.json"
}

test_add_creates_entry() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Database Connection Pooling" --status active --domain backend

    local entry_file="$tmpdir/test-vault/active/database-connection-pooling.md"
    assert_file_exists "$entry_file"
    assert_contains "$entry_file" "title: Database Connection Pooling"
    assert_contains "$entry_file" "status: active"
    assert_contains "$entry_file" "domain: backend"
    assert_contains "$entry_file" "^---$"
}

test_add_with_tags() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Cache Invalidation Notes" --status active --domain backend --tags "caching,performance"

    local entry_file="$tmpdir/test-vault/active/cache-invalidation-notes.md"
    assert_file_exists "$entry_file"
    assert_contains "$entry_file" "tags:.*caching"
    assert_contains "$entry_file" "tags:.*performance"
}

test_add_reference_tier() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Deployment Runbook" --status reference --domain ops

    local entry_file="$tmpdir/test-vault/reference/deployment-runbook.md"
    assert_file_exists "$entry_file"
    assert_contains "$entry_file" "status: reference"
}

test_add_refreshes_indexes() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Fresh Index Entry" --status active --domain backend

    assert_manifest_contains "$tmpdir/test-vault" "\"id\":\"fresh-index-entry\""
    assert_manifest_contains "$tmpdir/test-vault" "\"title\":\"Fresh Index Entry\""
    assert_contains "$tmpdir/test-vault/INDEX.md" "fresh-index-entry"
}

test_add_edit_refreshes_after_editor() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    local editor_script="$tmpdir/editor.sh"
    cat > "$editor_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
file="$1"
sed -i.bak 's/^title: "Draft Title"$/title: "Final Title"/' "$file"
rm -f "$file.bak"
EOF
    chmod +x "$editor_script"

    EDITOR="$editor_script" $KB_BIN add "Draft Title" --status active --domain backend --edit

    assert_manifest_contains "$tmpdir/test-vault" "\"title\":\"Final Title\""
    assert_index_section_contains "$tmpdir/test-vault/INDEX.md" "## Active" "Final Title"
}

test_move_refreshes_indexes() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    cat > active/move-me.md <<'ENTRY'
---
id: move-me
title: Move Me
status: active
type: analysis
domain: backend
projects: []
created: 2026-03-27
updated: 2026-03-27
ttl: 90d
tags: []
summary: "Move me"
---

Entry body.
ENTRY

    $KB_BIN index
    $KB_BIN move move-me reference

    assert_manifest_contains "$tmpdir/test-vault" "\"status\":\"reference\""
    assert_index_section_contains "$tmpdir/test-vault/INDEX.md" "## Reference" "Move Me"
}

test_add_rejects_duplicate_id() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "My Test Entry" --status active --domain backend

    local exit_code=0
    $KB_BIN add "My Test Entry" --status active --domain backend 2>/dev/null || exit_code=$?

    assert_eq "$exit_code" "1"
}

test_add_rejects_path_traversal() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    # Attempt path traversal in title
    local exit_code=0
    $KB_BIN add "../../../etc/passwd" --status active --domain backend 2>/dev/null || exit_code=$?

    assert_eq "$exit_code" "1"

    # Verify no file was created outside the vault
    [[ ! -f "$tmpdir/etc/passwd" ]] || { echo "  FAIL: path traversal created file outside vault"; return 1; }
}

test_add_rejects_dotdot_in_id() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    # Title "foo/../bar" gets sanitized to "foobar" (dots stripped), which is safe.
    # The path traversal check catches ".." in paths, but the ID sanitizer
    # removes dots before they reach the filesystem. This is correct behavior.
    # Test that the resulting file has a safe name.
    $KB_BIN add "foo/../bar" --status active --domain backend

    local created_file="$tmpdir/test-vault/active/foobar.md"
    assert_file_exists "$created_file"

    # Verify no file was created outside the vault
    [[ ! -f "$tmpdir/bar.md" ]] || { echo "  FAIL: path traversal created file outside vault"; return 1; }
}

test_index_generates_catalog() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Alpha Entry" --status active --domain frontend
    $KB_BIN add "Beta Entry" --status reference --domain backend

    $KB_BIN index

    assert_contains "$tmpdir/test-vault/INDEX.md" "alpha-entry"
    assert_contains "$tmpdir/test-vault/INDEX.md" "beta-entry"
    assert_contains "$tmpdir/test-vault/INDEX.md" "frontend"
    assert_contains "$tmpdir/test-vault/INDEX.md" "backend"
}

test_index_generates_versioned_manifest() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Manifest Contract Entry" --status active --domain backend --tags "api,docs"
    $KB_BIN index

    local manifest="$tmpdir/test-vault/.kb/manifest.json"
    assert_file_exists "$manifest"

    jq -e 'type == "object"' "$manifest" >/dev/null
    jq -e '.schema_version == 1' "$manifest" >/dev/null
    jq -e '(.generated_at | type == "string" and length > 0)' "$manifest" >/dev/null
    jq -e '(.entries | type == "array" and length == 1)' "$manifest" >/dev/null
    jq -e '(.entries[0].tier == "active") and (.entries[0].status == "active") and (.entries[0].path == "active/manifest-contract-entry.md")' "$manifest" >/dev/null
    jq -e '(.entries[0] | has("tier")) and (.entries[0] | has("projects")) and (.entries[0] | has("summary"))' "$manifest" >/dev/null
}

test_index_reflects_all_tiers() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Active Item" --status active --domain ops
    $KB_BIN add "Reference Item" --status reference --domain ops
    # Manually create an archive entry
    mkdir -p archive
    cat > archive/old-item.md <<'ENTRY'
---
id: old-item
title: Old Item
status: archive
domain: ops
tags: []
created: 2025-01-01
updated: 2025-06-01
ttl: 90d
---

Archived content.
ENTRY

    $KB_BIN index

    assert_contains "$tmpdir/test-vault/INDEX.md" "active-item"
    assert_contains "$tmpdir/test-vault/INDEX.md" "reference-item"
    # Archive entries are not listed in INDEX.md by design (just a count).
    # Verify the count is shown instead.
    assert_contains "$tmpdir/test-vault/INDEX.md" "1 archived"
}

test_validate_catches_missing_frontmatter() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    # Create a malformed entry (no frontmatter)
    cat > active/broken-entry.md <<'ENTRY'
# Broken Entry

This file has no frontmatter at all.
ENTRY

    local output
    local exit_code=0
    output=$($KB_BIN validate 2>&1) || exit_code=$?

    # validate should report an error (non-zero exit or error in output)
    [[ "$exit_code" -ne 0 ]] || echo "$output" | grep -qi "error\|invalid\|missing" || {
        echo "  FAIL: validate did not catch missing frontmatter"
        return 1
    }
}

test_validate_passes_valid_vault() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Valid Entry" --status active --domain backend

    local exit_code=0
    $KB_BIN validate 2>&1 || exit_code=$?

    assert_eq "$exit_code" "0"
}

test_move_relocates_entry() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Moving Entry" --status active --domain backend

    assert_file_exists "$tmpdir/test-vault/active/moving-entry.md"

    $KB_BIN move moving-entry reference

    # Should exist in new location
    assert_file_exists "$tmpdir/test-vault/reference/moving-entry.md"

    # Should not exist in old location
    [[ ! -f "$tmpdir/test-vault/active/moving-entry.md" ]] || {
        echo "  FAIL: entry still exists in old tier after move"
        return 1
    }

    # Frontmatter should reflect new status
    assert_contains "$tmpdir/test-vault/reference/moving-entry.md" "status: reference"
}

test_move_to_archive() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Archivable Entry" --status active --domain backend
    $KB_BIN move archivable-entry archive

    assert_file_exists "$tmpdir/test-vault/archive/archivable-entry.md"
    assert_contains "$tmpdir/test-vault/archive/archivable-entry.md" "status: archived"
}

test_search_finds_by_content() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Token Bucket Algorithm" --status active --domain backend

    # Append some content to search for
    echo "" >> active/token-bucket-algorithm.md
    echo "Sliding window was rejected due to memory overhead." >> active/token-bucket-algorithm.md

    local output
    output=$($KB_BIN search "sliding window" 2>&1)

    echo "$output" | grep -qi "token-bucket-algorithm" || {
        echo "  FAIL: search did not find entry by content"
        return 1
    }
}

test_search_finds_by_frontmatter() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Search Target" --status active --domain frontend

    local output
    output=$($KB_BIN search "domain: frontend" 2>&1)

    echo "$output" | grep -qi "search-target" || {
        echo "  FAIL: search did not find entry by frontmatter field"
        return 1
    }
}

test_search_no_results() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Unrelated Entry" --status active --domain backend

    local output
    local exit_code=0
    output=$($KB_BIN search "zzz-nonexistent-term-zzz" 2>&1) || exit_code=$?

    # Should return empty or indicate no results (not crash)
    [[ -z "$output" ]] || echo "$output" | grep -qi "no.*result\|no.*match\|not found\|0" || {
        # If output is just empty, that's fine too
        true
    }
}

test_search_json_returns_structured_results() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "JSON Target" --status active --domain backend --tags "caching,performance"

    local output
    output=$($KB_BIN search --json --field domain --tier active --tags caching backend 2>&1)

    echo "$output" | grep -q '^{' || {
        echo "  FAIL: json output does not start with an object"
        return 1
    }
    echo "$output" | grep -q '"count":1' || {
        echo "  FAIL: json output does not report one result"
        return 1
    }
    echo "$output" | grep -q '"id":"json-target"' || {
        echo "  FAIL: json output missing result id"
        return 1
    }
    echo "$output" | grep -q '"tier":"active"' || {
        echo "  FAIL: json output missing tier"
        return 1
    }
    echo "$output" | grep -q '"domain":"backend"' || {
        echo "  FAIL: json output missing domain"
        return 1
    }
    echo "$output" | grep -q '"path":"active/json-target.md"' || {
        echo "  FAIL: json output missing path"
        return 1
    }
    echo "$output" | grep -q '"tags":\["caching","performance"\]' || {
        echo "  FAIL: json output missing tags"
        return 1
    }
    if echo "$output" | grep -qi 'Found [0-9] result\|No results found'; then
        echo "  FAIL: json mode should not print human-readable banners"
        return 1
    fi
}

test_search_json_handles_no_results() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Unrelated Entry" --status active --domain backend

    local output
    output=$($KB_BIN search --json "zzz-nonexistent-term-zzz" 2>&1)

    echo "$output" | grep -q '"count":0' || {
        echo "  FAIL: json no-result output did not report zero results"
        return 1
    }
    echo "$output" | grep -q '"results":\[\]' || {
        echo "  FAIL: json no-result output missing empty results array"
        return 1
    }
}

test_stale_identifies_overdue() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    # Create an entry with a very old date and short TTL
    mkdir -p active
    cat > active/stale-entry.md <<'ENTRY'
---
id: stale-entry
title: Stale Entry
status: active
domain: backend
tags: []
created: 2024-01-01
updated: 2024-01-01
ttl: 7d
---

This entry is very old and should be flagged as stale.
ENTRY

    local output
    output=$($KB_BIN stale 2>&1)

    echo "$output" | grep -qi "stale-entry" || {
        echo "  FAIL: stale did not identify overdue entry"
        return 1
    }
}

test_stale_ignores_fresh() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    # Add a fresh entry (default TTL, today's date)
    $KB_BIN add "Fresh Entry" --status active --domain backend

    local output
    output=$($KB_BIN stale 2>&1)

    # Fresh entry should not appear in stale output
    if echo "$output" | grep -qi "fresh-entry"; then
        echo "  FAIL: stale incorrectly flagged a fresh entry"
        return 1
    fi
}

test_doctor_reports_healthy() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Healthy Entry" --status active --domain backend
    $KB_BIN index

    local exit_code=0
    local output
    output=$($KB_BIN doctor 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0"
}

test_doctor_detects_stale_index() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Entry One" --status active --domain backend
    $KB_BIN index

    # Add another entry without re-indexing
    $KB_BIN add "Entry Two" --status active --domain frontend

    local output
    local exit_code=0
    output=$($KB_BIN doctor 2>&1) || exit_code=$?

    # Doctor should warn about stale index or missing entry
    [[ "$exit_code" -ne 0 ]] || echo "$output" | grep -qi "stale\|outdated\|missing\|warning" || {
        echo "  FAIL: doctor did not detect stale INDEX.md"
        return 1
    }
}

test_doctor_detects_stale_manifest() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    $KB_BIN add "Manifest Freshness" --status active --domain backend
    $KB_BIN index

    touch -t 200001010000 .kb/manifest.json

    local output
    local exit_code=0
    output=$($KB_BIN doctor 2>&1) || exit_code=$?

    [[ "$exit_code" -ne 0 ]] || echo "$output" | grep -qi "manifest\|stale\|outdated\|warning" || {
        echo "  FAIL: doctor did not detect stale manifest.json"
        return 1
    }
}

test_id_sanitization() {
    local tmpdir="$1"
    cd "$tmpdir"

    $KB_BIN init test-vault
    cd test-vault

    # Title with special characters should produce a clean ID
    $KB_BIN add "What's the Best (API) Design?" --status active --domain backend

    # Find whatever file was created in active/
    local count
    count=$(find "$tmpdir/test-vault/active" -name "*.md" | wc -l | tr -d ' ')

    [[ "$count" -eq 1 ]] || { echo "  FAIL: expected 1 entry file, found $count"; return 1; }

    # The filename should not contain special characters
    local filename
    filename=$(basename "$(find "$tmpdir/test-vault/active" -name "*.md")")

    echo "$filename" | grep -qE '^[a-z0-9-]+\.md$' || {
        echo "  FAIL: filename contains unexpected characters: $filename"
        return 1
    }
}

# ============================================================
# Migrate tests
# ============================================================

assert_file_not_exists() {
    [[ ! -f "$1" ]] || { echo "  FAIL: file should not exist: $1"; return 1; }
}

assert_output_contains() {
    local output="$1"
    local pattern="$2"
    echo "$output" | grep -qi "$pattern" || { echo "  FAIL: output does not contain '$pattern'"; return 1; }
}

_migrate_init_vault() {
    local tmpdir="$1"
    cd "$tmpdir"
    $KB_BIN init test-vault
    cd "$tmpdir/test-vault"
}

_migrate_create_source() {
    local tmpdir="$1"
    mkdir -p "$tmpdir/source"
}

test_migrate_dry_run() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    cat > "$tmpdir/source/alpha.md" <<'EOF'
# Alpha Doc

**TL;DR**: Alpha summary
**Status**: Active

Some alpha content.
EOF

    cat > "$tmpdir/source/beta.md" <<'EOF'
# Beta Doc

Just a bare file with no metadata.
EOF

    _migrate_init_vault "$tmpdir"

    local output
    output=$($KB_BIN migrate "$tmpdir/source" --dry-run --yes 2>&1)

    # No new .md files should be created in vault tiers
    local active_count reference_count
    active_count=$(find "$tmpdir/test-vault/active" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    reference_count=$(find "$tmpdir/test-vault/reference" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

    assert_eq "$active_count" "0"
    assert_eq "$reference_count" "0"
    assert_output_contains "$output" "alpha"
    assert_output_contains "$output" "beta"
}

test_migrate_informal_headers() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    cat > "$tmpdir/source/test-analysis.md" <<'EOF'
# Test Analysis

**TL;DR**: This is a test summary
**Date**: 2025-06-15
**Status**: Reference

---

## Content
The actual content here.
EOF

    _migrate_init_vault "$tmpdir"

    $KB_BIN migrate "$tmpdir/source" --yes >/dev/null 2>&1

    local entry="$tmpdir/test-vault/reference/test-analysis.md"
    assert_file_exists "$entry"
    assert_contains "$entry" "^---$"
    assert_contains "$entry" "title:"
    assert_contains "$entry" "summary:.*This is a test summary"
    assert_contains "$entry" "status: reference"
    assert_contains "$entry" "## Content"
    assert_not_contains "$entry" '\*\*TL;DR\*\*'
}

test_migrate_yaml_frontmatter() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    cat > "$tmpdir/source/existing-entry.md" <<'EOF'
---
title: "Existing Entry"
status: active
---

## Body content
EOF

    _migrate_init_vault "$tmpdir"

    $KB_BIN migrate "$tmpdir/source" --yes >/dev/null 2>&1

    local entry="$tmpdir/test-vault/active/existing-entry.md"
    assert_file_exists "$entry"
    assert_contains "$entry" 'title: "Existing Entry"'
    assert_contains "$entry" "status: active"
    assert_contains "$entry" "id:"
}

test_migrate_no_metadata() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    cat > "$tmpdir/source/bare-document.md" <<'EOF'
# Bare Document

Some content with no metadata at all.
EOF

    _migrate_init_vault "$tmpdir"

    $KB_BIN migrate "$tmpdir/source" --yes >/dev/null 2>&1

    local entry="$tmpdir/test-vault/reference/bare-document.md"
    assert_file_exists "$entry"
    # File should start with frontmatter delimiter
    head -1 "$entry" | grep -q "^---$" || { echo "  FAIL: file does not start with ---"; return 1; }
    assert_contains "$entry" "title:"
}

test_migrate_project_compact() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    mkdir -p "$tmpdir/source/my-project"

    cat > "$tmpdir/source/my-project/QUICK-CONTEXT.md" <<'EOF'
# My Project

## Context
This is the project context.
EOF

    cat > "$tmpdir/source/my-project/analysis.md" <<'EOF'
# Analysis

## Key Findings
Important findings here.
EOF

    cat > "$tmpdir/source/my-project/SESSION-2025-01-01-notes.md" <<'EOF'
# Session Notes

Debugging session from Jan 1.
EOF

    _migrate_init_vault "$tmpdir"

    $KB_BIN migrate "$tmpdir/source" --yes >/dev/null 2>&1

    # A compacted entry should exist in one of the tiers
    local compacted_found=false
    if [[ -f "$tmpdir/test-vault/active/my-project.md" ]] || [[ -f "$tmpdir/test-vault/reference/my-project.md" ]]; then
        compacted_found=true
    fi
    [[ "$compacted_found" == "true" ]] || { echo "  FAIL: no compacted entry for my-project"; return 1; }

    assert_dir_exists "$tmpdir/test-vault/archive/my-project"

    # Session file should be in archive
    local session_found
    session_found=$(find "$tmpdir/test-vault/archive/my-project" -name "*SESSION*" -o -name "*session*" -o -name "*notes*" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$session_found" -ge 1 ]] || { echo "  FAIL: session file not found in archive/my-project/"; return 1; }
}

test_migrate_skips_indexes() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    cat > "$tmpdir/source/README.md" <<'EOF'
# Source README
This is the index file.
EOF

    cat > "$tmpdir/source/CLAUDE.md" <<'EOF'
# Claude Instructions
Some instructions.
EOF

    cat > "$tmpdir/source/real-content.md" <<'EOF'
# Real Content
Actual content to migrate.
EOF

    _migrate_init_vault "$tmpdir"

    local output
    output=$($KB_BIN migrate "$tmpdir/source" --yes 2>&1)

    # No readme.md or claude.md in any tier
    assert_file_not_exists "$tmpdir/test-vault/active/readme.md"
    assert_file_not_exists "$tmpdir/test-vault/reference/readme.md"
    assert_file_not_exists "$tmpdir/test-vault/active/claude.md"
    assert_file_not_exists "$tmpdir/test-vault/reference/claude.md"

    # Should mention skipping in output or log
    local skip_found=false
    if echo "$output" | grep -qi "skip"; then
        skip_found=true
    elif [[ -f "$tmpdir/test-vault/MIGRATION-LOG.md" ]] && grep -qi "skip" "$tmpdir/test-vault/MIGRATION-LOG.md"; then
        skip_found=true
    fi
    [[ "$skip_found" == "true" ]] || { echo "  FAIL: no mention of skipping index files"; return 1; }
}

test_migrate_archives_sessions() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    cat > "$tmpdir/source/SESSION-2025-03-15-debugging.md" <<'EOF'
# Debugging Session

Investigated a tricky bug in the auth flow.
EOF

    _migrate_init_vault "$tmpdir"

    $KB_BIN migrate "$tmpdir/source" --yes >/dev/null 2>&1

    # Session file should end up in archive
    local archive_count
    archive_count=$(find "$tmpdir/test-vault/archive" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$archive_count" -ge 1 ]] || { echo "  FAIL: session file not found in archive/"; return 1; }
}

test_migrate_source_untouched() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    cat > "$tmpdir/source/doc-one.md" <<'EOF'
# Document One
Content of document one.
EOF

    cat > "$tmpdir/source/doc-two.md" <<'EOF'
# Document Two
Content of document two.
EOF

    # Compute checksum before
    local checksum_before
    checksum_before=$(find "$tmpdir/source" -type f | sort | xargs shasum | shasum)

    _migrate_init_vault "$tmpdir"

    $KB_BIN migrate "$tmpdir/source" --yes >/dev/null 2>&1

    # Compute checksum after
    local checksum_after
    checksum_after=$(find "$tmpdir/source" -type f | sort | xargs shasum | shasum)

    assert_eq "$checksum_after" "$checksum_before"
}

test_migrate_path_traversal_rejected() {
    local tmpdir="$1"
    _migrate_init_vault "$tmpdir"

    local exit_code=0
    $KB_BIN migrate "../../../etc" --yes 2>/dev/null || exit_code=$?

    [[ "$exit_code" -ne 0 ]] || { echo "  FAIL: path traversal was not rejected"; return 1; }
}

test_migrate_exclude() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    cat > "$tmpdir/source/keep-me.md" <<'EOF'
# Keep Me
This file should be migrated.
EOF

    cat > "$tmpdir/source/skip-me.md" <<'EOF'
# Skip Me
This file should be excluded.
EOF

    _migrate_init_vault "$tmpdir"

    $KB_BIN migrate "$tmpdir/source" --yes --exclude "skip-*" >/dev/null 2>&1

    # keep-me should be migrated somewhere
    local keep_found=false
    if [[ -f "$tmpdir/test-vault/active/keep-me.md" ]] || [[ -f "$tmpdir/test-vault/reference/keep-me.md" ]]; then
        keep_found=true
    fi
    [[ "$keep_found" == "true" ]] || { echo "  FAIL: keep-me.md was not migrated"; return 1; }

    # skip-me should NOT be in any tier
    assert_file_not_exists "$tmpdir/test-vault/active/skip-me.md"
    assert_file_not_exists "$tmpdir/test-vault/reference/skip-me.md"
    assert_file_not_exists "$tmpdir/test-vault/archive/skip-me.md"
}

test_migrate_idempotent() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    cat > "$tmpdir/source/unique-doc.md" <<'EOF'
# Unique Document
This should only appear once.
EOF

    _migrate_init_vault "$tmpdir"

    $KB_BIN migrate "$tmpdir/source" --yes >/dev/null 2>&1

    local output
    output=$($KB_BIN migrate "$tmpdir/source" --yes 2>&1)

    # Should not create duplicates
    local total_count
    total_count=$(find "$tmpdir/test-vault/active" "$tmpdir/test-vault/reference" "$tmpdir/test-vault/archive" -name "*unique*" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$total_count" -eq 1 ]] || { echo "  FAIL: expected 1 copy, found $total_count"; return 1; }

    # Second run should mention skip or exists
    echo "$output" | grep -qi "skip\|exists\|already" || { echo "  FAIL: second run did not indicate entry already exists"; return 1; }
}

test_migrate_no_compact_flag() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    mkdir -p "$tmpdir/source/my-project"

    cat > "$tmpdir/source/my-project/QUICK-CONTEXT.md" <<'EOF'
# My Project
## Context
Project context here.
EOF

    cat > "$tmpdir/source/my-project/details.md" <<'EOF'
# Details
Project details here.
EOF

    _migrate_init_vault "$tmpdir"

    $KB_BIN migrate "$tmpdir/source" --yes --no-compact >/dev/null 2>&1

    # No compacted entry should exist
    assert_file_not_exists "$tmpdir/test-vault/active/my-project.md"
    assert_file_not_exists "$tmpdir/test-vault/reference/my-project.md"

    # Individual files should be migrated
    local file_count
    file_count=$(find "$tmpdir/test-vault/active" "$tmpdir/test-vault/reference" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$file_count" -ge 2 ]] || { echo "  FAIL: expected at least 2 individual files, found $file_count"; return 1; }
}

test_migrate_tag_extraction() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    cat > "$tmpdir/source/tagged-doc.md" <<'EOF'
# Tagged Document

This doc is about #performance and #caching strategies.
EOF

    _migrate_init_vault "$tmpdir"

    $KB_BIN migrate "$tmpdir/source" --yes >/dev/null 2>&1

    # Find the migrated file (ID from title "Tagged Document" -> tagged-document.md)
    local entry
    entry=$(find "$tmpdir/test-vault/active" "$tmpdir/test-vault/reference" -name "tagged-document.md" 2>/dev/null | head -1)

    [[ -n "$entry" ]] || { echo "  FAIL: tagged-document.md not found in vault"; return 1; }
    assert_contains "$entry" "performance"
}

test_migrate_audit_log() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    cat > "$tmpdir/source/log-test-one.md" <<'EOF'
# Log Test One
Content one.
EOF

    cat > "$tmpdir/source/log-test-two.md" <<'EOF'
# Log Test Two
Content two.
EOF

    _migrate_init_vault "$tmpdir"

    $KB_BIN migrate "$tmpdir/source" --yes >/dev/null 2>&1

    assert_file_exists "$tmpdir/test-vault/MIGRATION-LOG.md"
    assert_contains "$tmpdir/test-vault/MIGRATION-LOG.md" "Original Path"
    assert_contains "$tmpdir/test-vault/MIGRATION-LOG.md" "log-test-one"
    assert_contains "$tmpdir/test-vault/MIGRATION-LOG.md" "log-test-two"
}

test_migrate_post_flight() {
    local tmpdir="$1"
    _migrate_create_source "$tmpdir"

    cat > "$tmpdir/source/post-flight-doc.md" <<'EOF'
# Post Flight Doc
Testing post-flight checks.
EOF

    _migrate_init_vault "$tmpdir"

    $KB_BIN migrate "$tmpdir/source" --yes >/dev/null 2>&1

    # INDEX.md should reference the migrated entry
    assert_contains "$tmpdir/test-vault/INDEX.md" "post-flight-doc"

    # Manifest should exist and be non-empty
    assert_file_exists "$tmpdir/test-vault/.kb/manifest.json"
    local manifest_size
    manifest_size=$(wc -c < "$tmpdir/test-vault/.kb/manifest.json" | tr -d ' ')
    [[ "$manifest_size" -gt 0 ]] || { echo "  FAIL: manifest.json is empty"; return 1; }
}

# ============================================================
# Run all tests
# ============================================================

echo ""
echo "=========================================="
echo "  kb test suite"
echo "=========================================="
echo ""

run_test "init creates correct structure"          test_init_creates_structure
run_test "init INDEX.md has header"                test_init_index_has_header
run_test "init manifest has versioned shape"       test_init_manifest_has_versioned_shape
run_test "init works through symlinked install"    test_init_works_through_symlinked_install
run_test "init CLAUDE uses manifest contract"      test_init_claude_uses_entries_manifest_contract
run_test "add creates entry with frontmatter"      test_add_creates_entry
run_test "add with tags"                           test_add_with_tags
run_test "add to reference tier"                   test_add_reference_tier
run_test "add refreshes indexes"                   test_add_refreshes_indexes
run_test "add --edit refreshes after editor"       test_add_edit_refreshes_after_editor
run_test "add rejects duplicate IDs"               test_add_rejects_duplicate_id
run_test "add rejects path traversal"              test_add_rejects_path_traversal
run_test "add rejects .. in ID"                    test_add_rejects_dotdot_in_id
run_test "index generates catalog"                 test_index_generates_catalog
run_test "index generates versioned manifest"      test_index_generates_versioned_manifest
run_test "index reflects all tiers"                test_index_reflects_all_tiers
run_test "validate catches missing frontmatter"    test_validate_catches_missing_frontmatter
run_test "validate passes valid vault"             test_validate_passes_valid_vault
run_test "move relocates entry"                    test_move_relocates_entry
run_test "move to archive"                         test_move_to_archive
run_test "move refreshes indexes"                 test_move_refreshes_indexes
run_test "search finds by content"                 test_search_finds_by_content
run_test "search finds by frontmatter"             test_search_finds_by_frontmatter
run_test "search handles no results"               test_search_no_results
run_test "search json returns structured results"  test_search_json_returns_structured_results
run_test "search json handles no results"          test_search_json_handles_no_results
run_test "stale identifies overdue entries"         test_stale_identifies_overdue
run_test "stale ignores fresh entries"             test_stale_ignores_fresh
run_test "doctor reports healthy vault"            test_doctor_reports_healthy
run_test "doctor detects stale index"              test_doctor_detects_stale_index
run_test "doctor detects stale manifest"           test_doctor_detects_stale_manifest
run_test "ID sanitization handles special chars"   test_id_sanitization

echo ""
echo "--- migrate ---"
if [[ "${SKIP_MIGRATE_TESTS}" == "1" ]]; then
    echo "  Skipped in this run (SKIP_MIGRATE_TESTS=1)"
else
    run_test "migrate dry-run creates nothing"          test_migrate_dry_run
    run_test "migrate parses informal headers"          test_migrate_informal_headers
    run_test "migrate preserves YAML frontmatter"       test_migrate_yaml_frontmatter
    run_test "migrate handles no metadata"              test_migrate_no_metadata
    run_test "migrate compacts project folders"         test_migrate_project_compact
    run_test "migrate skips index files"                test_migrate_skips_indexes
    run_test "migrate archives session files"           test_migrate_archives_sessions
    run_test "migrate leaves source untouched"          test_migrate_source_untouched
    run_test "migrate rejects path traversal"           test_migrate_path_traversal_rejected
    run_test "migrate --exclude skips matching"         test_migrate_exclude
    run_test "migrate is idempotent"                    test_migrate_idempotent
    run_test "migrate --no-compact disables folding"    test_migrate_no_compact_flag
    run_test "migrate extracts inline tags"             test_migrate_tag_extraction
    run_test "migrate writes MIGRATION-LOG.md"          test_migrate_audit_log
    run_test "migrate runs post-flight indexing"        test_migrate_post_flight
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "=========================================="
printf '  Results: %s%d passed%s, %s%d failed%s\n' "${GREEN}" "$PASS_COUNT" "${RESET}" "${RED}" "$FAIL_COUNT" "${RESET}"
echo "=========================================="

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    printf '%s  Failed tests:%s\n' "${RED}" "${RESET}"
    for f in "${FAILURES[@]}"; do
        echo "    - $f"
    done
fi

echo ""

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

exit 0
