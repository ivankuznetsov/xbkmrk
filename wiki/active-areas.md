---
title: Active Areas
type: active-areas
source: git log --name-only; git status; README.md; lib/xbookmark/config.rb; lib/xbookmark/cli.rb
created: 2026-05-14
updated: 2026-08-16
tags: [activity]
---

**TLDR**: Current hardening centers on update-only Birdclaw import, explicit OpenRouter model routing, and preserving the existing transactional/coverage guarantees.

## Current Hardening Surface

The active production-hardening behavior is:

- Setup requires the OpenRouter key, keeps X credentials optional for Birdclaw-only installs, and installs the daily X scheduler only when both X identifiers are configured.
- `import-birdclaw` consumes the existing local archive in short read-only batches, skips terminal IDs without resetting retries, refreshes QMD, and does not require X credentials or construct an X client.
- OpenRouter uses `~deepseek/deepseek-v4-flash-latest` for text-only work and `qwen/qwen3.8-27b` for image-bearing prompts. Runtime does not launch local Codex.
- Linux scheduler setup tries to enable systemd linger through `loginctl enable-linger <user>` so the daily timer can fire after logout.
- Media downloads no longer impose the old 200 MB default cap; full-size X media is downloaded.
- Bookmark ingestion requests 50 items per X API page. Live production returned 4,745 unique bookmarks with `max_results=50`, but only 98 and no `next_token` with `max_results=100`.
- `WHISPER_MODEL=base.en` resolves to a local whisper.cpp `ggml-base.en.bin` model file when using `whisper-cli`/`whisper-cpp`; setup docs now include the model download step.
- Whisper transcription extracts downloaded video audio with `ffmpeg`, treats no-audio MP4s as empty transcripts, uses duration-aware timeouts, and runs whisper.cpp with up to 8 CPU threads by default.
- Large backfills now skip separate aux-page LLM summaries by default; author and concept pages are still written for Obsidian graph/backlinks, real thread pages are created only for multi-bookmark conversations, and `XBOOKMARK_AUX_SUMMARIES=true` restores extra author summaries.
- `Xbookmark::Qmd::Registrar` tries current `qmd collection list`/`collection add` first and preserves legacy command fallbacks.
- Specs cover OpenRouter routing/payload/error behavior, Birdclaw source mapping/import idempotence, the README setup contract, registrar fallback, and scheduler linger setup.
- `bundle exec rake coverage` runs Minitest under Ruby's built-in `Coverage` API and enforces 100% line coverage for `bin/` and `lib/`.
- The earlier `XBOOKMARK_WIKI_PATH` runtime wiki terminology is already on `main`.
- Production verification and reusable lessons are summarized in [[live-production-learnings]].

## OpenRouter Setup

- `xbookmark setup` can store the OpenRouter key through the host keystore.
- Offline config hydration makes the same key available to Birdclaw import and reenrichment without duplicating it in repository files.
- `xbookmark doctor` reports key presence plus the selected text and image model IDs.

## Setup Reliability

The README now describes only implemented setup commands:

- `bin/xbookmark auth login`
- `bin/xbookmark auth status`
- `bin/xbookmark auth refresh`
- `bin/xbookmark install`
- `bin/xbookmark backfill [--limit N]`
- `bin/xbookmark import-birdclaw [--db PATH] [--limit N]`
- `bin/xbookmark sync`
- `bin/xbookmark find QUERY [--limit N]`
- `bin/xbookmark install [--time HH:MM] [--dry-run] [--uninstall]`
- `bin/xbookmark setup`
- `bin/xbookmark uninstall --purge [--yes] [--dry-run]`

Deferred command shapes such as `schedule`, `auth logout`, `enrich`, `--config`, `backfill --since`, and `find --json` should stay out of setup docs until implemented.

Related: [[architecture]], [[commands]], [[api]], [[dependencies]], [[gaps]].
