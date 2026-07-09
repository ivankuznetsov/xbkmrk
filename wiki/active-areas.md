---
title: Active Areas
type: active-areas
source: git log --name-only; git status; README.md; lib/xbookmark/config.rb; lib/xbookmark/cli.rb
created: 2026-05-14
updated: 2026-07-09
tags: [activity]
---

**TLDR**: Production backfill reliability work, provider secret routing, 50-item bookmark pagination, Codex service-tier cleanup, and the 100% coverage gate are the current hardening focus.

## Current Hardening Surface

The active production-hardening behavior is:

- README setup now runs `bin/xbookmark install` as a required daily scheduler step instead of asking whether to install it.
- Linux scheduler setup tries to enable systemd linger through `loginctl enable-linger <user>` so the daily timer can fire after logout.
- Media downloads no longer impose the old 200 MB default cap; full-size X media is downloaded.
- Bookmark ingestion requests 50 items per X API page. Live production returned 4,745 unique bookmarks with `max_results=50`, but only 98 and no `next_token` with `max_results=100`.
- `WHISPER_MODEL=base.en` resolves to a local whisper.cpp `ggml-base.en.bin` model file when using `whisper-cli`/`whisper-cpp`; setup docs now include the model download step.
- Whisper transcription extracts downloaded video audio with `ffmpeg`, treats no-audio MP4s as empty transcripts, uses duration-aware timeouts, and runs whisper.cpp with up to 8 CPU threads by default.
- Large backfills now skip separate aux-page LLM summaries by default; author and concept pages are still written for Obsidian graph/backlinks, real thread pages are created only for multi-bookmark conversations, and `XBOOKMARK_AUX_SUMMARIES=true` restores extra author summaries.
- `Xbookmark::Qmd::Registrar` tries current `qmd collection list`/`collection add` first and preserves legacy command fallbacks.
- `Xbookmark::Enrich::Codex` unwraps current `codex exec --json` `item.completed` agent messages.
- Specs cover the README setup contract, legacy registrar fallback, scheduler linger setup, and current Codex JSON event parsing.
- `bundle exec rake coverage` runs Minitest under Ruby's built-in `Coverage` API and enforces 100% line coverage for `bin/` and `lib/`.
- The earlier `XBOOKMARK_WIKI_PATH` runtime wiki terminology is already on `main`.
- Provider secret routing now covers 1Password refs, platform keychain storage, exact `CI=true`/env-only mode, diagnostic `auth show`, and `auth.toml` routing without storing third-party API keys in checked-in files or shell history.
- Production verification and reusable lessons are summarized in [[live-production-learnings]].

## Service-Tier Setup Cleanup

- `lib/xbookmark/codex_config.rb` removes only stale invalid top-level `service_tier` values from the Codex config, preserves valid speed modes and project tables, and rewrites changed files atomically with mode `0600`.
- `xbookmark setup` calls that cleanup after collecting required X credentials and reports cleanup failures without failing the wizard.
- `xbookmark install` calls the cleanup for real installs, skips it for `--dry-run` and `--uninstall`, and treats cleanup failures as warnings so scheduler install and QMD registration can continue.
- Specs cover the config-file parser, atomic replacement failure behavior, setup wizard reporting, install warning behavior, and README contract against documented forced service tiers.

## Setup Reliability

The README now describes only implemented setup commands:

- `bin/xbookmark auth login`
- `bin/xbookmark auth status`
- `bin/xbookmark auth refresh`
- `bin/xbookmark install`
- `bin/xbookmark backfill [--limit N]`
- `bin/xbookmark sync`
- `bin/xbookmark find QUERY [--limit N]`
- `bin/xbookmark install [--time HH:MM] [--dry-run] [--uninstall]`
- `bin/xbookmark setup`
- `bin/xbookmark uninstall --purge [--yes] [--dry-run]`

Deferred command shapes such as `schedule`, `auth logout`, `enrich`, `--config`, `backfill --since`, and `find --json` should stay out of setup docs until implemented.

Related: [[architecture]], [[commands]], [[api]], [[dependencies]], [[gaps]].
