---
title: Commands
type: commands
source: bin/xbookmark; lib/xbookmark/cli.rb; lib/xbookmark/cli/*.rb; lib/xbookmark/config.rb; lib/xbookmark/qmd/registrar.rb; README.md; .env.example
created: 2026-05-14
updated: 2026-08-16
tags: [commands, cli]
---

**TLDR**: The implemented Thor CLI supports auth login/status/refresh, update-only Birdclaw import, optional X backfill/sync, OpenRouter re-enrichment, search, taxonomy maintenance, setup, install, doctor, and uninstall.

## Fresh Setup Contract

The README agent prompt should only reference implemented commands. A new setup flow is:

1. Clone and `bundle install`.
2. Copy `.env.example` to `.env`.
3. Fill `OPENROUTER_API_KEY`, `XBOOKMARK_WIKI_PATH`, and `BIRDCLAW_DB_PATH`.
4. Run `bin/xbookmark import-birdclaw` to update from already extracted bookmarks without an X backfill.
5. Add `X_CLIENT_ID`/`X_USER_ID`, run `auth login`, and install the scheduler only when direct X updates are wanted.
6. Verify with `bin/xbookmark --version` and `bin/xbookmark doctor`.

The runtime bookmark wiki created at `XBOOKMARK_WIKI_PATH` is separate from this repository's project LLM wiki in `wiki/`.

Packaged binary installs also support running `xbookmark` with no arguments in a TTY. That first-run path launches `xbookmark setup`, requires an OpenRouter key, accepts optional X credentials, and installs the daily scheduler only for a configured direct-X sync.

## Implemented Command Surface

- `bin/xbookmark` requires `lib/xbookmark/cli` and starts `Xbookmark::CLI`.
- `xbookmark version` prints `Xbookmark::VERSION`.
- `xbookmark auth login` runs OAuth 2.0 PKCE against X and writes tokens to the configured env file.
- `xbookmark auth status` reports whether an access token is present and still current; expired access tokens exit non-zero and point users at `auth refresh` or `auth login`.
- `xbookmark auth refresh` uses the saved refresh token to rotate OAuth tokens immediately, reports the token destination on success, and exits non-zero with a direct `auth login` hint when X rejects the refresh token.
- `xbookmark backfill [--limit N]` runs a limited test backfill when `--limit` is present and a full backfill otherwise.
- `xbookmark sync [--from-scheduler]` runs incremental X sync; scheduler invocations can skip if the last completed sync is too recent. Scheduled runs tolerate retryable X/OpenRouter trouble and retain pending work for the next run.
- `xbookmark import-birdclaw [--db PATH] [--limit N]` reads an existing Birdclaw SQLite archive in short read-only batches, never creates an X client, skips done/permanent tweet IDs, and applies `--limit` after those skips so bounded reruns advance.
- `xbookmark resync TWEET_ID` re-fetches and reprocesses one tweet.
- `xbookmark reenrich [--limit N]` re-runs the current enrichment contract over notes already in the wiki, offline. `Enrich::NoteSource` reconstructs each note's enrichment inputs (original tweet text, captions, transcripts) from the rendered note instead of re-fetching from X, so it never hits rate limits and never loses since-deleted tweets. It rewrites notes in place via `Pipeline#process_offline` (no media download/transcription, captions reused as the `vision:` context), is resumable (skips notes already at the current schema), and resets concept evidence counts on a fresh full run so the additive concept upserts do not double-count. See [[data-model]] and [[architecture]].
- `xbookmark find QUERY [--limit N]` searches the QMD `bookmarks` collection and prints numbered text results. `Qmd::Searcher` supplies explicit `lex:` and `vec:` query lines with `--no-rerank --format json`, avoiding QMD's local query-expansion and reranking model downloads, and caps parsed results to `N` even if the installed QMD returns extra hits. The collection is rooted at the bookmark wiki root, so source notes, author pages, and concept pages are searchable.
- `xbookmark taxonomy audit` reports graph-health problems without modifying files. Clean audits exit 0; audits with proposed changes exit 1.
- `xbookmark taxonomy rebuild [--apply]` performs an offline taxonomy repair workflow. Without `--apply`, it is a dry-run and reports proposed changes. With `--apply`, it snapshots generated wiki directories for manual recovery/audit evidence, writes a manifest and graph-health report under `.xbookmark`, renames numeric source notes, migrates real numeric thread pages to readable `thread-<id>` pages, prunes generated numeric singleton thread pages, materializes concept pages from local state, updates state paths, and reindexes QMD. Rebuilds are forward-only: completed repairs remain in place if a later operation reports `partial_failure`.
- `xbookmark doctor [--fix]` checks platform, scheduler, Ruby, keystore, wiki/state paths, OpenRouter routing/key presence, whisper, QMD, ffmpeg, and X auth. No local Codex binary is checked or required.
- `xbookmark install [--time HH:MM] [--dry-run] [--uninstall]` installs or removes the daily scheduler and registers QMD when installing.
- `xbookmark setup` imports legacy env-file credentials into the active keystore, requires an OpenRouter key, prompts for optional X keys, and installs the scheduler only when direct X sync is configured.
- `xbookmark uninstall --purge [--yes] [--dry-run]` removes scheduler units, keystore entries, and the config directory after explicit purge confirmation.

Global options visible in `Xbookmark::CLI` are `--wiki`, `--vault` as a legacy alias, and `--verbose`.

Configuration loaded by these commands comes from `XBOOKMARK_ENV_FILE`, `$PWD/.env`, and `~/.config/xbookmark/.env`, plus process environment values. The preferred bookmark wiki path key is `XBOOKMARK_WIKI_PATH`; `XBOOKMARK_VAULT`, `OBSIDIAN_VAULT_PATH`, and `--vault` are compatibility aliases.

## Command Flow

- `backfill`, `sync`, and `resync` all load config, open the SQLite state store, create an X API client, and delegate to `Xbookmark::Sync::Runner`.
- `import-birdclaw` loads offline config, opens the local Birdclaw archive read-only, shares the taxonomy lock with sync/rebuild, and delegates to `Xbookmark::Birdclaw::Importer` without loading X credentials.
- `auth refresh` loads config, invokes `Xbookmark::X::Auth#refresh!`, and writes rotated tokens to the same destination as `auth login`.
- `backfill` and `sync` first process cached pending/retry rows from SQLite. Rows with cached `payload_json` can be enriched without X; uncached legacy retry rows and new bookmark discovery still need X.
- `sync` starts from the newest bookmark page and stops after a page with no new bookmarks; X `next_token` values are not treated as durable cursors between runs.
- `find` delegates to `Xbookmark::Qmd::Searcher`.
- `taxonomy audit` delegates to `Xbookmark::Taxonomy::Auditor`; `taxonomy rebuild` delegates to `Xbookmark::Taxonomy::Rebuilder`.
- `install` delegates to `Xbookmark::Scheduler::Factory` and `Xbookmark::Qmd::Registrar`; `--dry-run` and `--uninstall` do not register QMD.
- `Xbookmark::Scheduler::Systemd` writes and enables the user timer, then runs `loginctl enable-linger <user>` when linger is not already enabled; failure is non-fatal and prints the manual command.
- The registrar supports current QMD `collection list`/`collection add` command shapes and legacy `list`/`register`/`index` fallbacks, with `qmd update` as the final legacy indexing fallback. It treats the old `vault_path/bookmarks` collection root as legacy and re-adds the collection at `vault_path`.
- `doctor` performs local binary and auth checks without running a sync. When optional tools are missing it prints package-manager one-liners where known; with `--fix` it asks before running each supported command.

## Deferred Public Surface

Do not document these commands as available until implementation lands:

- `auth logout`
- `enrich`
- `schedule install/status/uninstall`
- `backfill --since`, `--dry-run`, or `--overwrite`
- `find --type` or `--json`
- global `--config` or `XBOOKMARK_CONFIG`

Related: [[architecture]], [[api]], [[data-model]], [[dependencies]], [[gaps]].
