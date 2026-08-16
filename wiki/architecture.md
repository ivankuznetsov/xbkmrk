---
title: Architecture
type: architecture
source: git ls-files; lib/xbookmark/**/*.rb; README.md; .env.example; .llm-wiki/*
created: 2026-05-14
updated: 2026-08-16
tags: [architecture]
---

**TLDR**: `xbookmark` incrementally imports existing Birdclaw bookmarks or X API updates, enriches them through OpenRouter, and indexes the local markdown wiki with QMD.

## Repository Shape

- `main` tracks the runtime CLI, README, env template, CI config, specs, and project wiki.
- Production-hardening includes update-only Birdclaw import, explicit OpenRouter model routing, 50-item X pagination, and the 100% coverage gate.
- `.hive-state/config.yml` identifies the project as `xbookmark`, default branch `main`, worktree root `/home/asterio/Dev/xbookmark.worktrees`, and Hive review settings.

## Runtime CLI

The application is a Ruby command-line application named `xbookmark`. Its runtime shape is:

- Entry point: `bin/xbookmark` dispatches to `Xbookmark::CLI` in `lib/xbookmark/cli.rb`.
- Configuration: `Xbookmark::Config` reads `.env`/keyring sources and XDG/macOS defaults. Direct X commands require `X_CLIENT_ID` and `X_USER_ID`; offline Birdclaw import does not.
- Existing archive input: `Xbookmark::Birdclaw::Source` reads Birdclaw SQLite in read-only mode and `Importer` skips completed tweet IDs, so reruns are update-only and never perform a historical X fetch.
- X API integration: `Xbookmark::X::Auth` handles OAuth 2.0 PKCE and token refresh; `Xbookmark::X::Client` reads X bookmarks and tweet details from X API v2.
- State: `Xbookmark::State::Store` keeps local SQLite state under `<bookmark-wiki>/.xbookmark/state.db`, including cached per-bookmark X payloads for retryable local work.
- Sync loop: `Xbookmark::Sync::Runner` drives backfill, sync, and resync modes; it processes cached pending/retry rows before fetching new X pages, and `Xbookmark::Sync::Pipeline` processes one bookmark at a time.
- Media and transcription: `Xbookmark::Media::Downloader` downloads full-size X media without a default byte cap, and `Xbookmark::Transcribe::Whisper` extracts video audio through `ffmpeg` before shelling out to a local whisper backend with duration-aware timeouts.
- Enrichment: `Xbookmark::Enrich::Orchestrator` calls `Xbookmark::Enrich::OpenRouter`, routing text-only prompts to `~deepseek/deepseek-v4-flash-latest` and prompts with images to `qwen/qwen3.8-27b`.
- Taxonomy: `Xbookmark::Taxonomy::Normalizer`, `Registry`, `Curator`, `Auditor`, and `Rebuilder` canonicalize concepts, maintain SQLite concept metadata, produce graph-health reports, and repair existing generated wiki files offline without X access.
- Rendering: `Xbookmark::Render::BookmarkRenderer` writes readable per-bookmark source notes with a required tweet ID suffix; `ConceptPage` and `ConceptIndex` maintain canonical concept graph pages with explicit source-note post lists; `AuxPage` maintains authors and real thread pages while taxonomy rebuild migrates legacy topic/entity links into concepts and prunes the old landing pages. Author aux summaries remain opt-in through `XBOOKMARK_AUX_SUMMARIES`.
- Search: `Xbookmark::Qmd::Registrar` registers the `bookmarks` QMD collection at the bookmark wiki root through current `qmd collection` commands with legacy fallbacks; `Xbookmark::Qmd::Searcher` shells out to `qmd query`.
- Scheduling: `Xbookmark::Scheduler::Systemd` installs a user timer on Linux and tries to enable user linger; `Xbookmark::Scheduler::Launchd` installs a launch agent on macOS.
- Setup safety: the OpenRouter key is read from process/env files or hydrated from the host keystore for online and offline enrichment. Runtime commands do not use a local Codex executable or config.
- Coverage: `bundle exec rake coverage` uses Ruby's built-in `Coverage` API while running Minitest, then aborts unless every counted line under `bin/` and `lib/` is covered.

Related details: [[commands]], [[data-model]], [[dependencies]].

## Runtime Flow

```text
Birdclaw SQLite, X API bookmarks, or cached source payload
  -> local media download
  -> optional whisper transcription
  -> OpenRouter concept-candidate enrichment
  -> deterministic taxonomy normalization
  -> readable markdown + concept pages + media in the bookmark wiki
  -> QMD indexing for search
```

Per-bookmark work uses a scratch directory and atomic writes before updating state, so a failed bookmark is retried rather than leaving partial final output. Image-model failures degrade to DeepSeek text-only enrichment and mark the result partial. Birdclaw import and other wiki writers share an advisory taxonomy lock. Scheduled X runs retain their source-outage behavior.

The generated wiki is organized as source notes, authors, concepts, and facets. Source notes live under `bookmarks/YYYY/MM/DD/` with filenames like `alice-apple-management-2047091470201700828.md`; raw tweet IDs remain in frontmatter and filename suffixes for stability. Real thread pages keep the conversation ID only as a suffix and use cached local tweet text, falling back to local bookmark summaries, for the leading slug and wikilink label, so graph nodes are topic-like instead of `thread-<id>` placeholders. Concepts live under `concepts/` with `broader` links so Obsidian graph edges carry hierarchy, and concept pages include `## Posts` lists built from local source-note frontmatter; parent concepts inherit child concept posts so broad pages like `venezuela` are useful entry points. Nested tags such as `area/venezuela` and `facet/politics` are filters rather than the main graph hierarchy. `xbookmark taxonomy audit` and `xbookmark taxonomy rebuild --apply` operate from local markdown and SQLite state, materialize concept pages from persisted concept metadata, rewrite legacy topic/entity frontmatter and wikilinks to `concepts/`, prune old topic/entity landing pages, rename placeholder thread pages from cached payload text or rendered note summaries, write manifests under `.xbookmark`, keep forward repairs in place on partial failures, and do not require live X access. Scheduled taxonomy maintenance also runs the curator over a bounded batch of persisted concepts with a scheduler-specific LLM timeout, falling back to deterministic rules if OpenRouter is unavailable or too slow.

## Cross-Project Wiki Context

Configured main wiki path `/home/asterio/wikis/master/wiki` exists. A search for `xbookmark`, bookmark, Hive, and related terms found no xbookmark-specific page; only portfolio-wide Rails conventions and patterns were relevant. Because this repository is a Ruby CLI rather than a Rails app, those Rails conventions are background context, not architecture evidence for this project.

## Maintenance

Managed LLM wiki context lives in `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, and `wiki/`.

Related: [[dependencies]], [[active-areas]], [[commands]], [[api]], [[data-model]], [[gaps]].
