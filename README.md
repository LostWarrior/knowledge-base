# kb

A markdown knowledge base for humans and AI agents.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## The Problem

Knowledge accumulated across coding sessions - analyses, session notes, runbooks, architectural decisions - becomes unmanageable fast. Files proliferate across directories, indexes go stale within days, and AI coding agents waste hundreds of tokens navigating a sprawl of context files just to figure out what exists.

Existing solutions don't quite fit:

- **Beads** adds structured metadata but requires a specific runtime and schema setup
- **Mem0** handles deduplication well but depends on external vector stores and APIs
- **Letta** provides long-term memory for agents but brings heavyweight infrastructure
- **ReMe** compacts markdown nicely but lacks lifecycle management

Engineers need something that works with `git`, reads like plain text, and doesn't require installing a language runtime or standing up a service.

## The Solution

`kb` is a zero-dependency CLI that manages a tiered, frontmatter-indexed markdown vault. It is built entirely with bash and standard unix tools - nothing to install, nothing to break.

Optimized for both human browsing and AI agent context loading. `INDEX.md` provides a human-readable catalog, while `.kb/manifest.json` gives agents a machine-readable index they can query with `jq` for just the entries they need.

## Quick Start

### Install

```bash
# Install directly without tapping first
brew install LostWarrior/knowledge-base/kb

# Or tap first, then install by formula name
brew tap LostWarrior/knowledge-base
brew install kb

# Or install the notarized macOS package from a GitHub release
# https://github.com/LostWarrior/knowledge-base/releases

# Or from source
git clone https://github.com/LostWarrior/knowledge-base.git
cd knowledge-base && make install
```

### First vault

```bash
# Initialize a new vault
kb init my-vault && cd my-vault

# Add an entry
kb add "API Rate Limiting Strategy" --status active --domain backend

# Rebuild the index
kb index

# Check vault health
kb status
```

## Vault Structure

```
my-vault/
├── INDEX.md              # Auto-generated entry catalog (~150 tokens)
├── CLAUDE.md             # Auto-generated agent instructions
├── active/               # Current, high-priority entries
│   ├── api-rate-limiting-strategy.md
│   └── database-connection-pooling.md
├── reference/            # Stable, long-lived entries
│   ├── deployment-runbook.md
│   └── error-code-catalog.md
├── archive/              # Superseded or expired entries
│   └── old-auth-flow-notes.md
└── .kb/                  # Internal metadata
    ├── config.yml
    └── manifest.json     # Machine-readable index (auto-generated)
```

**Tiers** control lifecycle and visibility:

| Tier | Purpose | Default TTL |
|------|---------|-------------|
| `active` | Work in progress, session notes, current investigations | 14 days |
| `reference` | Stable knowledge, runbooks, decision records | 90 days |
| `archive` | Superseded or expired entries, kept for history | none |

## Entry Format

Every entry is a standard markdown file with YAML frontmatter:

```markdown
---
id: api-rate-limiting-strategy
title: API Rate Limiting Strategy
status: active
domain: backend
tags: [performance, api, throttling]
created: 2026-01-15
updated: 2026-03-20
ttl: 14d
---

## Context

The public API needs rate limiting to prevent abuse and ensure
fair usage across tenants.

## Decision

Token bucket algorithm with per-tenant quotas stored in a
distributed cache. Limits configured via environment variables.

## Notes

- Evaluated sliding window approach, rejected due to memory overhead
- Load tested at 10x expected traffic, no issues observed
```

## Commands

| Command | Description |
|---------|-------------|
| `kb init <name>` | Create a new vault with directory structure and config |
| `kb add <title> [--status S] [--domain D] [--tags T]` | Create a new entry with frontmatter in the correct tier |
| `kb edit <id>` | Open an entry in `$EDITOR` |
| `kb move <id> <tier>` | Move an entry between tiers and update its frontmatter |
| `kb index` | Regenerate `INDEX.md` and `.kb/manifest.json` from all entries |
| `kb search <query> [--json]` | Search entries by content and frontmatter fields; `--json` emits structured results |
| `kb validate` | Check all entries for valid frontmatter |
| `kb stale` | List entries past their TTL |
| `kb doctor` | Full vault health check (structure, index freshness, orphans) |
| `kb status` | Summary of vault contents by tier and domain |
| `kb compact <id>` | Deterministic concatenation and deduplication of an entry (no LLM) |
| `kb distill <dir> [--keep] [--model M]` | LLM-powered summarization of session files (requires API key) |
| `kb migrate <source-dir> [flags]` | Import a markdown directory into the vault |
| `kb export [--format json]` | Export vault metadata as JSON |

## Migration

Import an existing markdown collection into a structured vault:

```bash
kb init my-vault && cd my-vault
kb migrate ~/Documents/notes --dry-run    # preview first
kb migrate ~/Documents/notes              # execute
```

The migrate command:
- **Scans** source files and extracts metadata (YAML frontmatter, `**TL;DR**`/`**Status**` headers, or filename heuristics)
- **Previews** a full migration plan before touching anything
- **Copies** files into vault tiers with proper YAML frontmatter (source directory is never modified)
- **Compacts** project folders into single reference entries (originals preserved in archive/)
- **Archives** session files verbatim
- Writes `MIGRATION-LOG.md` for full traceability
- Auto-runs `kb index` and `kb doctor` post-migration

Flags:
| Flag | Description |
|------|-------------|
| `--dry-run` | Preview the migration plan without executing |
| `--yes` | Skip confirmation prompt |
| `--no-compact` | Treat all files as standalone (no folder compaction) |
| `--exclude <glob>` | Exclude files matching pattern (repeatable) |

## Design Principles

1. **Markdown-first, zero dependencies.** Pure bash and standard unix tools. No Python, no Node, no Go binary. Runs anywhere with a POSIX shell.

2. **Tiered lifecycle with TTL-based staleness.** Entries move through `active` -> `reference` -> `archive` as they age or become superseded. TTL values surface stale entries before they rot silently.

3. **Dual-output discovery.** `INDEX.md` gives humans a browsable catalog (~150 tokens). `.kb/manifest.json` gives agents a machine-readable index queryable with `jq` or `grep` (~200 tokens for a targeted subset). No multi-file navigation, no directory walking, no database queries.

4. **Structured frontmatter enables grep as a power-user escape hatch.** The YAML frontmatter is designed so that `grep -r "domain: backend" active/` just works. No special query language needed - standard unix tools are the API.

5. **Inspired by the best ideas in the space:**
   - **Beads** - structured metadata and schema discipline
   - **ReMe** - markdown-first storage with compaction
   - **Mem0** - deduplication awareness and memory lifecycle

## AI Agent Integration

When you run `kb init`, a `CLAUDE.md` file is generated in the vault root. This file teaches AI coding agents how to use the vault:

```markdown
# Knowledge Base

This directory is a `kb` vault - a structured markdown knowledge base.

## For AI Agents

1. Read `INDEX.md` first - it contains the full entry catalog (~150 tokens)
2. Each entry has YAML frontmatter with: id, title, status, domain, tags, created, updated, ttl
3. Entries are organized by lifecycle tier: active/, reference/, archive/
4. To find entries: check INDEX.md or use `grep -r "domain: <name>" active/`
5. Prefer reading active/ and reference/ entries - archive/ is historical only

## Quick Commands

- View what exists: read INDEX.md
- Find by domain: grep -r "domain: backend" active/ reference/
- Find by tag: grep -r "tags:.*caching" active/ reference/
```

Agents that support `CLAUDE.md` (or equivalent instruction files) will automatically discover the vault and know how to navigate it efficiently.

For programmatic agent access, `.kb/manifest.json` is the primary discovery mechanism. Instead of parsing a markdown table, agents can query the JSON manifest directly:

```bash
# Find all active entries in a domain
jq '.entries[] | select(.tier == "active" and .domain == "backend")' .kb/manifest.json

# List entry IDs and titles
jq -r '.entries[] | "\(.id)\t\(.title)"' .kb/manifest.json
```

This costs ~200 tokens for the relevant subset vs ~10k tokens to parse a large INDEX.md table. INDEX.md remains available for humans browsing in their editor or on GitHub.

For direct structured retrieval during search, use `kb search --json "<query>"` and filter results on the fields you need without parsing the markdown output.

## Comparison

| Feature | kb | Beads | ReMe | Mem0 |
|---------|-----|-------|------|------|
| Dependencies | None (bash) | Go CLI + Dolt backend | Python package + model/storage config | Python or Node OSS + model/vector-store config |
| Storage | Markdown files | Dolt-backed SQL database | File-based summaries plus vector-based memory | Vector store + history store |
| Agent-optimized | Yes (manifest.json, INDEX.md, CLAUDE.md) | Partial | No | Yes (API) |
| Human-readable | Yes (plain markdown) | Partial | Partial | Mostly no |
| Install complexity | `make install` | Homebrew/npm/Go/curl install | `pip install` + config | Python/Node SDK + config |
| Git-friendly | Yes (diff-friendly text) | Partial | Partial | Limited |
| Lifecycle tiers | Yes (active/reference/archive) | No | No | No |
| TTL / staleness | Yes | Partial | Partial | Partial |
| Offline | Yes | Yes | Partial | Yes (OSS) |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on submitting issues and pull requests.

## Releases

Tagged releases (`v*`) publish three assets:

- `kb-<version>.tar.gz` for Homebrew
- `SHA256SUMS.txt` for release verification
- `kb-<version>.pkg` signed and notarized for macOS

The Homebrew formula lives in [`Formula/kb.rb`](Formula/kb.rb) and is updated automatically by the release workflow after each tagged release.
Apple signing and notarization are isolated in the reusable workflow at [`.github/workflows/notarize-macos.yml`](.github/workflows/notarize-macos.yml), so the main release workflow only passes version metadata and explicit GitHub secrets into that boundary.

### GitHub Secrets For Notarization

Add these repository secrets before cutting a release:

- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_PRIVATE_KEY`
- `APPLE_DEVELOPER_ID_INSTALLER_P12`
- `APPLE_DEVELOPER_ID_INSTALLER_P12_PASSWORD`

`APPLE_DEVELOPER_ID_INSTALLER_P12` should contain the base64-encoded Developer ID Installer certificate export. The workflow auto-detects the imported `Developer ID Installer: ...` identity, so no separate secret is needed for the certificate name. All signing and notarization credentials are read from GitHub Actions secrets, masked in workflow logs, and written only to temporary runner files that are deleted at the end of the notarization job.

## License

[MIT](LICENSE)
