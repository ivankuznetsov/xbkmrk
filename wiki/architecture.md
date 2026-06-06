---
title: Architecture
type: architecture
source: git ls-files; lib/xbookmark/**/*.rb; README.md; .env.example; .llm-wiki/*
created: 2026-05-14
updated: 2026-07-09
tags: [architecture]
---

**TLDR**: `xbookmark` is a Ruby CLI that ingests X bookmarks into a standalone local bookmark wiki, enriches them locally, and indexes them with QMD.

## Repository Shape

- `main` tracks the runtime CLI, README, env template, CI config, specs, and project wiki.
- Production-hardening work includes 50-item X bookmark pagination, Codex stdin prompt delivery, stale service-tier cleanup, and the 100% coverage gate.
- `.hive-state/config.yml` identifies the project as `xbookmark`, default branch `main`, worktree root `/home/asterio/Dev/xbookmark.worktrees`, and Hive review settings.

## Runtime CLI

The application is a Ruby command-line application named `xbookmark`. Its runtime shape is:

- Entry point: `bin/xbookmark` dispatches to `Xbookmark::CLI` in `lib/xbookmark/cli.rb`.
- Configuration: `Xbookmark::Config` reads `.env` sources and XDG/macOS defaults, hydrates missing known X OAuth keys from the best-effort keystore, and requires `X_CLIENT_ID` and `X_USER_ID`.
- Credential storage: `Xbookmark::Keystore` chooses macOS Keychain, Linux libsecret, or an env-file fallback for known X OAuth keys. Provider API-key routing uses `Xbookmark::Keystore::Provider`, `AuthConfig`, and `Resolver`: provider names share `Provider::NAME_PATTERN` validation across CLI parsing and `auth.toml` loading; exact `CI=true` or `XBOOKMARK_KEYS_FROM_ENV=1` forces environment lookup and skips `auth.toml`; otherwise `~/.config/xbookmark/auth.toml` can route a provider to 1Password (`op://...`) or the platform keychain before falling back to `XBOOKMARK_<PROVIDER>_KEY` environment variables. Linux keychain routing requires both `secret-tool` and a D-Bus session.
- X API integration: `Xbookmark::X::Auth` handles OAuth 2.0 PKCE and token refresh; `Xbookmark::X::Client` reads X bookmarks and tweet details from X API v2.
- State: `Xbookmark::State::Store` keeps local SQLite state under `<bookmark-wiki>/.xbookmark/state.db`, including cached per-bookmark X payloads for retryable local work.
- Sync loop: `Xbookmark::Sync::Runner` drives backfill, sync, and resync modes; it processes cached pending/retry rows before fetching new X pages, and `Xbookmark::Sync::Pipeline` processes one bookmark at a time.
- Media and transcription: `Xbookmark::Media::Downloader` downloads full-size X media without a default byte cap, and `Xbookmark::Transcribe::Whisper` extracts video audio through `ffmpeg` before shelling out to a local whisper backend with duration-aware timeouts.
- Enrichment: `Xbookmark::Enrich::Orchestrator` calls `Xbookmark::Enrich::Codex`, fetches allowed external links, runs image OCR/captioning, and returns structured concept candidates rather than legacy topic/entity strings.
- Taxonomy: `Xbookmark::Taxonomy::Normalizer`, `Registry`, `Curator`, `Auditor`, and `Rebuilder` canonicalize concepts, maintain SQLite concept metadata, produce graph-health reports, and repair existing generated wiki files offline without X access.
- Rendering: `Xbookmark::Render::BookmarkRenderer` writes readable per-bookmark source notes with a required tweet ID suffix; `ConceptPage` and `ConceptIndex` maintain canonical concept graph pages with explicit source-note post lists; `AuxPage` maintains authors and real thread pages while taxonomy rebuild migrates legacy topic/entity links into concepts and prunes the old landing pages. Author aux summaries remain opt-in through `XBOOKMARK_AUX_SUMMARIES`.
- Search: `Xbookmark::Qmd::Registrar` registers the `bookmarks` QMD collection at the bookmark wiki root through current `qmd collection` commands with legacy fallbacks; `Xbookmark::Qmd::Searcher` shells out to `qmd query`.
- Scheduling: `Xbookmark::Scheduler::Systemd` installs a user timer on Linux and tries to enable user linger; `Xbookmark::Scheduler::Launchd` installs a launch agent on macOS.
- Setup safety: `Xbookmark::CodexConfig` removes only stale invalid top-level `service_tier` values in `~/.codex/config.toml` or `$CODEX_HOME/config.toml`, preserves valid speed modes and project tables, and rewrites changed config files atomically with `0600` permissions.
- Coverage: `bundle exec rake coverage` uses Ruby's built-in `Coverage` API while running Minitest, then aborts unless every counted line under `bin/` and `lib/` is covered.

Related details: [[commands]], [[data-model]], [[dependencies]].

## Runtime Flow

```text
X API bookmarks or cached source payload
  -> local media download
  -> optional whisper transcription
  -> codex concept-candidate enrichment
  -> deterministic taxonomy normalization
  -> readable markdown + concept pages + media in the bookmark wiki
  -> QMD indexing for search
```

Per-bookmark work uses a scratch directory and atomic writes before updating state, so a failed bookmark should be retried rather than leaving partial final output. Image-based Codex failures degrade to text-only enrichment for that bookmark and mark the result partial, so one flaky vision response does not block the note. Scheduled runs tolerate source-only X auth, rate-limit, and transport failures: they report `source blocked`, keep taxonomy maintenance, QMD indexing, and cached local work running, and avoid stamping `last_sync_finished_at` until a source-clean run completes.

The generated wiki is organized as source notes, authors, concepts, and facets. Source notes live under `bookmarks/YYYY/MM/DD/` with filenames like `alice-apple-management-2047091470201700828.md`; raw tweet IDs remain in frontmatter and filename suffixes for stability. Real thread pages keep the conversation ID only as a suffix and use cached local tweet text, falling back to local bookmark summaries, for the leading slug and wikilink label, so graph nodes are topic-like instead of `thread-<id>` placeholders. Concepts live under `concepts/` with `broader` links so Obsidian graph edges carry hierarchy, and concept pages include `## Posts` lists built from local source-note frontmatter; parent concepts inherit child concept posts so broad pages like `venezuela` are useful entry points. Nested tags such as `area/venezuela` and `facet/politics` are filters rather than the main graph hierarchy. `xbookmark taxonomy audit` and `xbookmark taxonomy rebuild --apply` operate from local markdown and SQLite state, materialize concept pages from persisted concept metadata, rewrite legacy topic/entity frontmatter and wikilinks to `concepts/`, prune old topic/entity landing pages, rename placeholder thread pages from cached payload text or rendered note summaries, write manifests under `.xbookmark`, keep forward repairs in place on partial failures, and do not require live X access. Scheduled taxonomy maintenance also runs the curator over a bounded batch of persisted concepts with a scheduler-specific LLM timeout, falling back to deterministic rules if Codex is unavailable or too slow.

## Cross-Project Wiki Context

Configured main wiki path `/home/asterio/wikis/master/wiki` exists. A search for `xbookmark`, bookmark, Hive, and related terms found no xbookmark-specific page; only portfolio-wide Rails conventions and patterns were relevant. Because this repository is a Ruby CLI rather than a Rails app, those Rails conventions are background context, not architecture evidence for this project.

## Maintenance

Managed LLM wiki context lives in `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, and `wiki/`.

Related: [[dependencies]], [[active-areas]], [[commands]], [[api]], [[data-model]], [[gaps]].
