# Knowledge Base - Agent Rules

- The manifest is a top-level object with `schema_version`, `generated_at`, and `entries`
- ALWAYS check `.kb/manifest.json` before reading any files in this vault
- Use `jq` or `grep` on the manifest to find relevant entries by domain, tags, or status
- Do NOT scan directories or read INDEX.md for navigation - the manifest is your source of truth
- INDEX.md is for human consumption only
- Entries in archive/ are cold storage - only read if explicitly asked
- When creating or updating entries, always maintain YAML frontmatter
- After changes, run `kb index` to regenerate both INDEX.md and manifest.json

## Manifest Query Examples

```bash
# Find active entries
jq '.entries[] | select(.tier == "active")' .kb/manifest.json

# Find entries by domain
jq '.entries[] | select(.domain == "backend")' .kb/manifest.json

# Find entries by tag
jq '.entries[] | select(.tags | index("api"))' .kb/manifest.json

# List entry IDs and titles
jq -r '.entries[] | "\(.id)\t\(.title)"' .kb/manifest.json
```

## Entry Frontmatter Format

```yaml
---
id: entry-slug
title: "Entry Title"
status: active | reference | archived
type: analysis | session | guide | report | runbook
domain: backend | infrastructure | career | tooling | general
projects: []
created: YYYY-MM-DD
updated: YYYY-MM-DD
ttl: 90d
tags: []
summary: "One sentence description."
---
```
