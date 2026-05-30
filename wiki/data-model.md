---
title: Data Model
type: data-model
source: lib/xbookmark/state/migrations.rb; lib/xbookmark/state/store.rb; lib/xbookmark/render/bookmark_renderer.rb
created: 2026-05-14
updated: 2026-07-09
tags: [data, sqlite, bookmark-wiki]
---

**TLDR**: xbookmark stores sync metadata, bookmark status, concept metadata, and optional aux-page summary metadata in SQLite, while final user-facing data lives as markdown and media files in a standalone bookmark wiki.

## Scope

The data model is tracked on `main`. The current SQLite schema version is 3.

## SQLite State DB

`Xbookmark::State::Migrations` creates a single schema at `<bookmark-wiki>/.xbookmark/state.db`:

- `meta(key TEXT PRIMARY KEY, value TEXT)`
- `bookmarks(tweet_id TEXT PRIMARY KEY, author_handle TEXT NOT NULL, bookmarked_at TEXT NOT NULL, ingested_at TEXT, status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, markdown_path TEXT, enrichment_digest TEXT, payload_json TEXT)`
- `idx_bookmarks_status` on `bookmarks(status)`
- `pages(kind TEXT NOT NULL, slug TEXT NOT NULL, path TEXT NOT NULL, last_summarized_at TEXT, summary_input_digest TEXT, PRIMARY KEY(kind, slug))`
- `concepts(slug TEXT PRIMARY KEY, label TEXT NOT NULL, kind TEXT NOT NULL, aliases_json TEXT NOT NULL DEFAULT '[]', broader_json TEXT NOT NULL DEFAULT '[]', facets_json TEXT NOT NULL DEFAULT '[]', evidence_count INTEGER NOT NULL DEFAULT 0, confidence REAL NOT NULL DEFAULT 0.0, curator_outcome TEXT NOT NULL DEFAULT 'canonical', updated_at TEXT)`
- `curator_decisions(id INTEGER PRIMARY KEY AUTOINCREMENT, slug TEXT NOT NULL, decision_json TEXT NOT NULL, created_at TEXT NOT NULL)`

`Migrations.apply!` creates tables/indexes if missing and stamps `schema_version = 3`. Version 2 adds `bookmarks.payload_json`, which stores a minimized per-bookmark X API payload so pending and retryable rows can be enriched later without re-fetching the tweet first. The v2 migration also repairs databases that were stamped version 2 before the physical column existed. Version 3 adds concept metadata and seeds concept rows from existing legacy topic/entity page rows.

## Bookmark Note Frontmatter (schema 2)

`Render::SCHEMA_VERSION` is `2`. Bookmark notes render YAML frontmatter as queryable Obsidian Properties:

- `title` — a concise human title (drives the filename and graph label; defaults to the summary's first clause).
- `created_at` / `bookmarked_at` — typed dates (`YYYY-MM-DD`), so Bases/Dataview can sort and filter them; the original string is kept if it cannot be parsed.
- `tags` — the flat keyword vocabulary (the live filtering signal). The earlier concept-derived `facets` key is dropped because nothing populated it.
- `concepts` — bare concept slugs (queryable); the body's `## Concepts` section carries the clickable `[[concepts/…]]` graph links.
- `concept_labels`, `author`, `author_id`, `author_name`, `conversation_id`, `thread`, `links`, `media`, `summary`, `enrichment_status` as before.

Concept pages carry a single semantic `kind` (one of `area`, `subtopic`, `entity`, `technology`, `place`, `organization`, `idea`; legacy/unknown kinds are coerced into this set) and never write synthetic `topics`/`entities` parents into `broader`.

`taxonomy rebuild --apply` migrates existing schema-1 notes to this shape in place — bumping the version, typing the dates, backfilling `title`, and dropping `facets` — offline (no re-enrichment), gated on the schema version so re-runs are no-ops. Existing readable filenames are not renamed during migration; only new notes adopt title-based names.

## Status and Mode Values

Bookmark status constants in `Xbookmark::State::Store`:

- `pending`
- `done`
- `needs_retry`
- `permanent_error`

Sync mode constants:

- `fresh`
- `test_backfilled`
- `fully_backfilled`
- `incremental`

Failures increment `attempts`; after three attempts or a permanent error flag, the bookmark becomes `permanent_error`. `Store.record_failure` returns the final stored status so the sync report can distinguish rows that remain retryable from rows promoted to permanent during the current run. Successful processing resets attempts and clears `last_error`. Global source outages such as X auth, rate-limit, and transport failures are reported separately as `source blocked`; they do not count as per-bookmark permanent errors.

## Bookmark Wiki Layout

The renderer writes final markdown under:

```text
<bookmark-wiki>/bookmarks/YYYY/MM/DD/<readable-slug>-<tweet_id>.md
<bookmark-wiki>/media/<tweet_id>/*
<bookmark-wiki>/authors/<handle>.md
<bookmark-wiki>/concepts/<slug>.md
<bookmark-wiki>/concepts/index.md
<bookmark-wiki>/threads/<readable-thread-slug>.md
<bookmark-wiki>/.xbookmark/state.db
<bookmark-wiki>/.xbookmark/scratch/*
<bookmark-wiki>/.xbookmark/taxonomy-*.manifest.json
<bookmark-wiki>/.xbookmark/taxonomy-*.graph-health.json
```

## Auth Routing TOML

Provider API-key routing lives outside the bookmark wiki at `~/.config/xbookmark/auth.toml`. It records one section per provider with a backend (`1password` or `keychain`) and, for 1Password, an `op://...` reference. It intentionally stores no secret values; actual values remain in 1Password, the host keychain, or environment variables such as `XBOOKMARK_OPENROUTER_KEY`.

Bookmark markdown frontmatter includes `xbookmark_schema`, tweet and author fields, timestamps, sanitized tags, canonical concept slugs/labels, facet tags, media records, conversation/thread references, links, summary, and `enrichment_status`.

Concept pages include `kind: concept`, `slug`, `label`, `concept_kind`, `aliases`, `broader`, `tags`, `evidence_count`, `confidence`, and `curator_outcome`. `broader` relationships are also rendered as wikilinks so Obsidian graph edges show hierarchy, except generic legacy roots such as `topics` and `entities` remain frontmatter-only and are not rendered as graph hubs. Concept pages include a generated `## Posts` section linking to matching bookmark source notes and inherit post references from narrower child concepts through `broader`. Taxonomy rebuild migrates legacy `topics:`/`entities:` source-note frontmatter and `[[topics/...]]`/`[[entities/...]]` wikilinks into canonical `concepts:` and `[[concepts/...]]`, then prunes the old topic/entity landing pages.

## Transactional Behavior

`Xbookmark::Sync::Pipeline` processes one bookmark in scratch space, moves media into the final bookmark wiki location, writes markdown via `AtomicWriter`, then ensures author/concept/thread pages and removes scratch. Author aux summaries are only generated when `XBOOKMARK_AUX_SUMMARIES` is enabled. Singleton conversations do not create thread pages; `Xbookmark::Sync::ThreadIndex` creates readable thread pages only when local state proves a real multi-bookmark conversation. If a transient or permanent error occurs, scratch is removed and state is updated through `Store.record_failure`. Sync runs process cached pending/retry rows before asking X for new pages, and cached rows are ordered before uncached rows so degraded source-outage runs still do local enrichable work.

Taxonomy rebuilds are local data migrations. `xbookmark taxonomy rebuild --apply` writes a pre-apply snapshot and manifest under `.xbookmark`, renames numeric source notes, migrates real numeric thread pages to readable `thread-<id>` pages, prunes generated numeric singleton thread pages, materializes concept pages from SQLite concept metadata, refreshes concept/topic/entity post lists from local bookmark frontmatter, updates `bookmarks.markdown_path` and generated page rows through path-only store methods, writes a graph-health report, and reindexes QMD. Rebuilds are forward-only: snapshots are manual recovery/audit evidence, while `partial_failure` leaves completed file repairs visible. Dry-run/audit reports use explicit states: `clean`, `proposed_changes`, `blocked_conflicts`, `applied`, and `partial_failure`.

Related: [[architecture]], [[commands]], [[dependencies]], [[gaps]].
