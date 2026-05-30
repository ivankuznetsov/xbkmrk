---
title: Decisions
type: decisions
source: git log; git worktree list; .hive-state/config.yml; lib/xbookmark/**/*.rb; README.md; .env.example
created: 2026-05-14
updated: 2026-07-09
tags: [decisions]
---

**TLDR**: Current durable decisions center on an unreleased Ruby CLI that creates a standalone bookmark wiki from X data, separate from this repository's project LLM wiki.

## Repository and Workflow Decisions

- `main` now carries the runtime CLI, README, specs, CI config, and project wiki; the older minimal-baseline state is historical only.
- `.hive-state/` is ignored by `.gitignore` and used as the local Hive workflow state store.
- Hive is configured with default branch `main`, worktree root `/home/asterio/Dev/xbookmark.worktrees`, `max_review_passes: 2`, and multiple reviewer agents.
- LLM wiki maintenance is managed through `.llm-wiki/` with `codex` as the headless maintenance agent.

## Runtime CLI Decisions

- Use Ruby with a Bundler/gemspec layout and a Thor CLI (`bin/xbookmark`, `lib/xbookmark/cli.rb`).
- Use official X API v2 with OAuth 2.0 PKCE and scopes visible in `Xbookmark::X::Auth`.
- Use 50-item pages for `GET /2/users/:user_id/bookmarks`; live production showed `max_results=100` can omit pagination even when older bookmarks exist.
- Require `X_CLIENT_ID` and `X_USER_ID` at config load time; store access and refresh tokens back into the env file with file mode `0600`.
- Store third-party provider API-key routing in `~/.config/xbookmark/auth.toml`, not the key values. Provider values should resolve from 1Password, the host keychain, or environment variables, with `CI=true` and `XBOOKMARK_KEYS_FROM_ENV=1` forcing env-only lookup.
- Create a standalone bookmark wiki at `XBOOKMARK_WIKI_PATH`, separate from the project LLM wiki in `wiki/`.
- Default new installs to `xbookmark-wiki`; migration from the earlier local `xbookmark-vault` name is not needed because the product has not been released.
- Store local sync state and concept metadata in SQLite at `<bookmark-wiki>/.xbookmark/state.db`.
- Store minimized per-bookmark X payloads in SQLite for newly discovered bookmarks and resyncs. This lets pending and retryable rows continue enrichment later without depending on X availability, while new bookmark discovery still requires X.
- Treat each bookmark as a transactional unit: scratch media/transcription/enrichment first, final markdown/media writes after success, then state update.
- Use Codex headless CLI for LLM enrichment instead of a direct provider SDK.
- Pass Codex prompts over stdin instead of argv so large bookmark/media/transcript prompts do not exceed OS argument-size limits.
- Remove stale invalid top-level Codex `service_tier` values during setup/install so scheduled enrichment and wiki maintenance are not blocked by old `default`/`flex` config, while preserving intentional valid speed modes.
- Use local Whisper tooling for audio/video transcription.
- Replace graph-facing topic/entity pages with canonical concept pages. Codex returns bounded concept candidates; deterministic local normalization owns canonical slugs, alias cleanup, recurrence thresholds, and demonym/acronym handling.
- Use readable bookmark filenames with mandatory tweet ID suffixes. The raw ID remains in frontmatter and filenames for stability, while Obsidian graph labels become human-readable.
- Suppress singleton thread pages. Only local evidence of a real multi-bookmark conversation creates a readable thread page.
- Use concept wikilinks for graph hierarchy and nested tags only as facets.
- Treat taxonomy rebuild snapshots as manual recovery/audit evidence, not automatic rollback. Rebuilds are forward-only and report `partial_failure` if a later operation fails after earlier repairs completed.
- Run scheduled taxonomy curation from local concept state. Codex-driven curator output is sanitized through the concept model and falls back to deterministic rules when Codex is unavailable, so local maintenance does not depend on live X access or a successful LLM call.
- Register and query a QMD collection named `bookmarks` at the bookmark wiki root; current QMD `collection list`/`collection add` commands are preferred, with legacy `list`/`register`/`index` fallbacks.
- Use systemd user timers on Linux and launchd on macOS for daily sync, make scheduler installation part of the default setup flow, and enable Linux systemd linger when possible so daily timers can run after logout.
- Scheduled sync should tolerate X source-only failures. It should continue local taxonomy cleanup, QMD maintenance, and cached retry/enrichment work, report `source blocked`, exit successfully when no local bookmark work failed, and avoid stamping `last_sync_finished_at` so the next timer can fetch new bookmarks after reauth.
- Fail closed for external link fetch safety by rejecting private, loopback, link-local, reserved, multicast, and metadata-address ranges.

## README Setup Decisions

- The README agent prompt must only reference commands that exist in the CLI so fresh installs work without manual correction.
- `bin/xbookmark install` is the scheduler command and default setup step; on Linux it should try `loginctl enable-linger <user>` after enabling the timer. Do not document `schedule install/status/uninstall` until those subcommands exist.
- `XBOOKMARK_ENV_FILE` is the alternate config-file selector; do not document `--config` or `XBOOKMARK_CONFIG` until implemented.
- `XBOOKMARK_WIKI_PATH` and `--wiki` are the preferred bookmark wiki path controls. `XBOOKMARK_VAULT`, `OBSIDIAN_VAULT_PATH`, and `--vault` remain compatibility aliases.
- `auth login` binds the callback host/port from `X_REDIRECT_URI`; there is no `auth login --port` option.

## Recent History Signals

- `origin/main`: `64ba268 Merge pull request #38 from ivankuznetsov/fix/paginate-bookmarks-stable-page-size`, after the production setup/backfill hardening PRs landed.
- `Xbookmark::CodexConfig` owns Codex config cleanup for setup/install and rewrites changed config files atomically with `0600` permissions.
- Production validation showed the X bookmark endpoint exposes thousands of bookmarks when requested at 50 per page. The earlier 98-bookmark result was caused by using `max_results=100`, which returned no `next_token`.
- The most important production findings are summarized in [[live-production-learnings]].

Related: [[architecture]], [[commands]], [[api]], [[data-model]], [[active-areas]], [[gaps]].
