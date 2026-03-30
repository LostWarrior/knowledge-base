
**Plain-text project context for you and your AI.**

## TL;DR

`kb` is a zero-dependency CLI for organizing project context in markdown so it stays readable in your editor and efficient for AI tools.

## Why This Exists

This started with a simple workflow: keep useful context from ongoing projects in markdown. Notes, runbooks, decisions, analyses, and session logs all lived in one place, with enough structure to stay readable.

Over time, that structure stopped being enough. Even with dates, `TL;DR`s, status fields, and pointers between files, the repository became harder to navigate than it should have been. The problem was not writing things down. The problem was finding the right context later.

That friction showed up for me first. Finding the right context meant opening too many files, following too many links, and turning what was supposed to save time into a tangled web of markdown files. It slowed agents down too. They had to spend too many tokens scanning files just to figure out what was relevant before they could do any real work.

Existing tools solve parts of this well, but they often come with tradeoffs: more infrastructure than necessary, external systems, opinionated runtimes, or weak lifecycle management for the content itself.

`kb` is simpler: plain text, local, git-friendly, and lightweight enough to fit into a normal development workflow. It keeps markdown-based context readable in a normal editor while giving AI tools a faster and more efficient way to navigate the same knowledge.

## The Solution

`kb` turns a folder of markdown files into a structured knowledge base with two ways to navigate the same content:

1. `INDEX.md` for browsing and reading in your editor.
2. `.kb/manifest.json` for AI agents to filter relevant context before opening files.

Built with bash and standard unix tools, `kb` stays local, readable, and efficient.

## Quick Start

### Install

```bash
# Install directly from the dedicated Homebrew tap:
# https://github.com/LostWarrior/homebrew-knowledge-base
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
| `kb index` | Regenerate `INDEX.md` and the versioned `.kb/manifest.json` contract from all entries |
| `kb search <query> [--json]` | Search entries by content and frontmatter fields; `--json` emits structured results |
| `kb validate` | Check all entries for valid frontmatter |
| `kb stale` | List entries past their TTL |
| `kb doctor` | Full vault health check (structure, generated-artifact freshness, orphans) |
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

1. Read `.kb/manifest.json` first - it is the source of truth for discovery
2. The manifest is a top-level object with `schema_version`, `generated_at`, and `entries`
3. Each manifest entry includes: `id`, `tier`, `title`, `status`, `type`, `domain`, `path`, `updated`, `tags`, `projects`, and `summary`
4. Use `jq` to filter manifest entries before opening full markdown files
5. Prefer reading active/ and reference/ entries - archive/ is historical only

## Quick Commands

- View what exists: `jq '.entries[] | {id, tier, title}' .kb/manifest.json`
- Find by domain: `jq '.entries[] | select(.domain == "backend")' .kb/manifest.json`
- Find by tag: `jq '.entries[] | select(.tags | index("caching"))' .kb/manifest.json`
```

Agents that support `CLAUDE.md` (or equivalent instruction files) will automatically discover the vault and know how to navigate it efficiently.

For programmatic agent access, `.kb/manifest.json` is the primary discovery mechanism. It is a versioned top-level object with `schema_version`, `generated_at`, and `entries`. Instead of parsing a markdown table, agents can query the manifest directly:

```bash
# Find all active entries in a domain
jq '.entries[] | select(.tier == "active" and .domain == "backend")' .kb/manifest.json

# List entry IDs and titles
jq -r '.entries[] | "\(.id)\t\(.title)"' .kb/manifest.json
```

This costs ~200 tokens for the relevant subset vs ~10k tokens to parse a large INDEX.md table. INDEX.md remains available for humans browsing in their editor or on GitHub.

For direct structured retrieval during search, use `kb search --json "<query>"` and filter results on the fields you need without parsing the human-readable search output.

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
