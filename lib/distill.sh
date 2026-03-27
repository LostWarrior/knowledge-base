#!/usr/bin/env bash
set -euo pipefail

# kb distill - LLM-powered summarization of session notes
# Reads all .md files in a directory, sends to LLM API, generates a single reference entry

# --- Cleanup ---
TMPFILES=()
cleanup() {
    for f in "${TMPFILES[@]}"; do
        rm -f "$f"
    done
}
trap cleanup EXIT

# --- Defaults ---
KEEP=false
MODEL_PROVIDER="claude"

# --- Usage ---
usage() {
    cat <<EOF
Usage: kb distill <directory> [options]

Summarize all .md files in a directory into a single reference entry.

Options:
  --keep           Don't archive originals after distilling
  --model TYPE     LLM provider: claude (default) or openai

Environment:
  ANTHROPIC_API_KEY   Required when using --model claude
  OPENAI_API_KEY      Required when using --model openai

Examples:
  kb distill active/sessions/
  kb distill active/sessions/ --keep
  kb distill active/sessions/ --model openai
EOF
}

# --- Parse args ---
TARGET_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            KEEP=true
            shift
            ;;
        --model)
            if [[ -z "${2:-}" ]]; then
                echo "error: --model requires a value (claude or openai)" >&2
                exit 1
            fi
            MODEL_PROVIDER="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            echo "error: unknown option '$1'" >&2
            exit 1
            ;;
        *)
            if [[ -z "${TARGET_DIR}" ]]; then
                TARGET_DIR="$1"
            else
                echo "error: unexpected argument '$1'" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "${TARGET_DIR}" ]]; then
    echo "error: directory argument required" >&2
    usage
    exit 1
fi

# --- Validate model provider ---
if [[ "${MODEL_PROVIDER}" != "claude" && "${MODEL_PROVIDER}" != "openai" ]]; then
    echo "error: --model must be 'claude' or 'openai'" >&2
    exit 1
fi

# --- Validate path (no ..) ---
if [[ "${TARGET_DIR}" == *".."* ]]; then
    echo "error: path must not contain '..'" >&2
    exit 1
fi

# --- Resolve target directory ---
if [[ "${TARGET_DIR}" != /* ]]; then
    TARGET_DIR="${VAULT_ROOT}/${TARGET_DIR}"
fi

if [[ ! -d "${TARGET_DIR}" ]]; then
    echo "error: directory not found: ${TARGET_DIR}" >&2
    exit 1
fi

# --- Validate API key ---
if [[ "${MODEL_PROVIDER}" == "claude" ]]; then
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        echo "error: ANTHROPIC_API_KEY is not set" >&2
        echo "Export your API key: export ANTHROPIC_API_KEY=sk-..." >&2
        exit 1
    fi
elif [[ "${MODEL_PROVIDER}" == "openai" ]]; then
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        echo "error: OPENAI_API_KEY is not set" >&2
        echo "Export your API key: export OPENAI_API_KEY=sk-..." >&2
        exit 1
    fi
fi

# --- Collect .md files ---
md_files=()
while IFS= read -r -d '' f; do
    md_files+=("$f")
done < <(find "${TARGET_DIR}" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)

if [[ ${#md_files[@]} -eq 0 ]]; then
    echo "error: no .md files found in ${TARGET_DIR}" >&2
    exit 1
fi

echo "Found ${#md_files[@]} markdown file(s) in ${TARGET_DIR}"

# --- Build combined content ---
combined_tmp="$(mktemp)"
TMPFILES+=("${combined_tmp}")

for f in "${md_files[@]}"; do
    basename_f="$(basename "$f")"
    {
        printf '=== FILE: %s ===\n' "${basename_f}"
        cat "$f"
        printf '\n\n'
    } >> "${combined_tmp}"
done

# --- Escape content for JSON ---
escaped_content="$(python3 -c "
import sys, json
with open(sys.argv[1], 'r') as f:
    print(json.dumps(f.read()))
" "${combined_tmp}")"

SYSTEM_PROMPT="Summarize these session notes into a single reference document. Preserve: key decisions, findings, action items, and important context. Remove: redundancy, session-specific noise, raw logs. Output format: markdown with sections for Context, Key Findings, Decision Log, and Artifacts."

# --- Make API call ---
response_tmp="$(mktemp)"
TMPFILES+=("${response_tmp}")

echo "Sending to ${MODEL_PROVIDER} API..."

if [[ "${MODEL_PROVIDER}" == "claude" ]]; then
    request_body="$(printf '{"model":"claude-sonnet-4-20250514","max_tokens":4096,"system":"%s","messages":[{"role":"user","content":%s}]}' \
        "${SYSTEM_PROMPT}" "${escaped_content}")"

    http_code="$(curl -s -w '%{http_code}' -o "${response_tmp}" \
        -X POST "https://api.anthropic.com/v1/messages" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -d "${request_body}")"

    if [[ "${http_code}" != "200" ]]; then
        echo "error: Claude API returned HTTP ${http_code}" >&2
        cat "${response_tmp}" >&2
        exit 1
    fi

    # Extract text content from response using python (safe, no eval)
    output_content="$(python3 -c "
import sys, json
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
for block in data.get('content', []):
    if block.get('type') == 'text':
        print(block['text'])
" "${response_tmp}")"

elif [[ "${MODEL_PROVIDER}" == "openai" ]]; then
    request_body="$(printf '{"model":"gpt-4o","max_tokens":4096,"messages":[{"role":"system","content":"%s"},{"role":"user","content":%s}]}' \
        "${SYSTEM_PROMPT}" "${escaped_content}")"

    http_code="$(curl -s -w '%{http_code}' -o "${response_tmp}" \
        -X POST "https://api.openai.com/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${OPENAI_API_KEY}" \
        -d "${request_body}")"

    if [[ "${http_code}" != "200" ]]; then
        echo "error: OpenAI API returned HTTP ${http_code}" >&2
        cat "${response_tmp}" >&2
        exit 1
    fi

    # Extract message content from response using python (safe, no eval)
    output_content="$(python3 -c "
import sys, json
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
choices = data.get('choices', [])
if choices:
    print(choices[0].get('message', {}).get('content', ''))
" "${response_tmp}")"
fi

if [[ -z "${output_content:-}" ]]; then
    echo "error: empty response from API" >&2
    exit 1
fi

# --- Sanitize LLM output: strip any frontmatter the LLM might generate ---
sanitized_content="$(printf '%s' "${output_content}" | sed '/^---$/,/^---$/d')"

# If sed stripped everything (unlikely), fall back to original
if [[ -z "${sanitized_content}" ]]; then
    sanitized_content="${output_content}"
fi

# --- Generate output entry ---
dir_name="$(basename "${TARGET_DIR}")"
entry_id="distill-${dir_name}"
today="$(date +%Y-%m-%d)"

output_file="${TARGET_DIR}/${entry_id}.md"

cat > "${output_file}" <<ENTRY
---
id: ${entry_id}
title: "Distilled: ${dir_name}"
status: reference
type: report
domain: general
projects: []
created: ${today}
updated: ${today}
ttl: 90d
tags: [distilled]
summary: "Distilled summary of ${#md_files[@]} files from ${dir_name}."
---

${sanitized_content}
ENTRY

echo "Created: ${output_file}"

# --- Archive originals (unless --keep) ---
if [[ "${KEEP}" == "false" ]]; then
    archive_dir="${VAULT_ROOT}/archive"
    mkdir -p "${archive_dir}"

    for f in "${md_files[@]}"; do
        basename_f="$(basename "$f")"
        # Don't archive the file we just created
        if [[ "$f" == "${output_file}" ]]; then
            continue
        fi
        mv "$f" "${archive_dir}/${basename_f}"
        echo "Archived: ${basename_f}"
    done
fi

echo ""
echo "Done. Run 'kb index' to update INDEX.md and manifest.json."
