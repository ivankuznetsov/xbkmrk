---
title: Commands
type: commands
source: bin/xbookmark; lib/xbookmark/cli.rb; lib/xbookmark/cli/*.rb; lib/xbookmark/config.rb; lib/xbookmark/qmd/registrar.rb; README.md; .env.example
created: 2026-05-14
updated: 2026-07-09
tags: [commands, cli]
---

**TLDR**: The README and implementation are aligned around the currently implemented Thor CLI: auth login/bind/list/rm/status/refresh, backfill, sync, resync, reenrich, find, taxonomy audit/rebuild, doctor/doctor --fix, install, setup, and uninstall.

## Fresh Setup Contract

The README agent prompt should only reference implemented commands. A new setup flow is:

1. Clone and `bundle install`.
2. Copy `.env.example` to `.env`.
3. Fill `X_CLIENT_ID`, `X_USER_ID`, optional `X_CLIENT_SECRET`, `X_REDIRECT_URI`, and `XBOOKMARK_WIKI_PATH`.
4. Run `bin/xbookmark auth login`.
5. Run `bin/xbookmark install` to install the daily scheduler and, on Linux, enable systemd linger when possible.
6. Verify with `bin/xbookmark --version` and `bin/xbookmark auth status`.

The runtime bookmark wiki created at `XBOOKMARK_WIKI_PATH` is separate from this repository's project LLM wiki in `wiki/`.

Packaged binary installs also support running `xbookmark` with no arguments in a TTY. That first-run path launches `xbookmark setup`, writes required X credentials into the keystore when available, removes stale invalid top-level Codex `service_tier` values, and installs the daily scheduler.

## Implemented Command Surface

- `bin/xbookmark` requires `lib/xbookmark/cli` and starts `Xbookmark::CLI`.
- `xbookmark version` prints `Xbookmark::VERSION`.
- `xbookmark auth login` runs OAuth 2.0 PKCE against X and writes tokens to the configured env file.
- `xbookmark auth login PROVIDER` prompts for a third-party provider key without echoing input, writes it to the platform keychain backend, and records keychain routing in `auth.toml`.
- `xbookmark auth bind PROVIDER OP_REF` validates an `op://...` 1Password reference, smoke-checks it when the `op` CLI is available, and records 1Password routing without storing the secret value.
- `xbookmark auth list` shows configured provider names and backends from `auth.toml` plus environment variables without printing secret values.
- `xbookmark auth rm PROVIDER` removes provider routing and deletes the platform-keychain entry when the provider was routed to `keychain`.
- `xbookmark auth status` reports whether an access token is present and still current; expired access tokens exit non-zero and point users at `auth refresh` or `auth login`.
- `xbookmark auth refresh` uses the saved refresh token to rotate OAuth tokens immediately, reports the token destination on success, and exits non-zero with a direct `auth login` hint when X rejects the refresh token.
- `xbookmark backfill [--limit N]` runs a limited test backfill when `--limit` is present and a full backfill otherwise.
- `xbookmark sync [--from-scheduler]` runs incremental sync; scheduler invocations can skip if the last completed sync is too recent. A scheduled run is best-effort: it tolerates all retryable trouble — source outages (X auth down/rate-limited) AND transient enrichment failures (codex glitches that auto-retry next run) — exiting 0 so the timer doesn't report `failed` for things that heal themselves; it logs/reports `source blocked`, keeps local taxonomy cleanup/QMD maintenance/cached retry work running, and does not stamp `last_sync_finished_at` on a source outage. A scheduled run still fails (non-zero) only on permanent errors or destructive maintenance failures. Manual sync surfaces everything: it exits non-zero on source errors and transient retries.
- `xbookmark resync TWEET_ID` re-fetches and reprocesses one tweet.
- `xbookmark reenrich [--limit N]` re-runs the current enrichment contract over notes already in the wiki, offline. `Enrich::NoteSource` reconstructs each note's enrichment inputs (original tweet text, captions, transcripts) from the rendered note instead of re-fetching from X, so it never hits rate limits and never loses since-deleted tweets. It rewrites notes in place via `Pipeline#process_offline` (no media download/transcription, captions reused as the `vision:` context), is resumable (skips notes already at the current schema), and resets concept evidence counts on a fresh full run so the additive concept upserts do not double-count. See [[data-model]] and [[architecture]].
- `xbookmark find QUERY [--limit N]` searches the QMD `bookmarks` collection and prints numbered text results. `Qmd::Searcher` invokes `qmd query --collection bookmarks --types lex,vec --limit N --json QUERY` and caps parsed results to `N` even if the installed QMD returns extra hits. The collection is rooted at the bookmark wiki root, so source notes, author pages, and concept pages are searchable.
- `xbookmark taxonomy audit` reports graph-health problems without modifying files. Clean audits exit 0; audits with proposed changes exit 1.
- `xbookmark taxonomy rebuild [--apply]` performs an offline taxonomy repair workflow. Without `--apply`, it is a dry-run and reports proposed changes. With `--apply`, it snapshots generated wiki directories for manual recovery/audit evidence, writes a manifest and graph-health report under `.xbookmark`, renames numeric source notes, migrates real numeric thread pages to readable `thread-<id>` pages, prunes generated numeric singleton thread pages, materializes concept pages from local state, updates state paths, and reindexes QMD. Rebuilds are forward-only: completed repairs remain in place if a later operation reports `partial_failure`.
- `xbookmark doctor [--fix]` checks platform, scheduler backend, Ruby runtime, keystore backend, bookmark wiki path, state DB path, `codex`, whisper, `qmd`, `ffmpeg`, and X auth token presence. It is diagnostic and exits 0 even when optional tools are missing; `--fix` prompts before running supported package-manager install commands.
- `xbookmark install [--time HH:MM] [--dry-run] [--uninstall]` installs or removes the daily scheduler and registers QMD when installing. Non-dry-run installs also remove stale invalid top-level Codex `service_tier` values before writing scheduler state, but cleanup failures are warnings. Linux installs try to enable systemd linger so the timer can fire after logout.
- `xbookmark setup` is the interactive first-run wizard. It imports legacy env-file credentials into the active keystore, prompts for missing X keys, removes stale invalid Codex `service_tier` values, and installs the scheduler. Service-tier cleanup and scheduler failures are reported but do not abort the wizard.
- `xbookmark uninstall --purge [--yes] [--dry-run]` removes scheduler units, keystore entries, and the config directory after explicit purge confirmation.

Global options visible in `Xbookmark::CLI` are `--wiki`, `--vault` as a legacy alias, and `--verbose`.

Configuration loaded by these commands comes from `XBOOKMARK_ENV_FILE`, `$PWD/.env`, and `~/.config/xbookmark/.env`, plus process environment values. The preferred bookmark wiki path key is `XBOOKMARK_WIKI_PATH`; `XBOOKMARK_VAULT`, `OBSIDIAN_VAULT_PATH`, and `--vault` are compatibility aliases.

Provider credential resolution uses `Xbookmark::Keystore::Resolver`: exact `CI=true` or `XBOOKMARK_KEYS_FROM_ENV=1` forces environment lookup and skips `auth.toml`; outside that mode, `auth.toml` can route providers to 1Password or the platform keychain, and plain environment variables are the final fallback. Linux keychain routing requires both `secret-tool` and a non-empty D-Bus session address.

## Command Flow

- `backfill`, `sync`, and `resync` all load config, open the SQLite state store, create an X API client, and delegate to `Xbookmark::Sync::Runner`.
- `auth refresh` loads config, invokes `Xbookmark::X::Auth#refresh!`, and writes rotated tokens to the same destination as `auth login`.
- `auth login PROVIDER`, `auth bind`, `auth list`, `auth rm`, and provider lookups delegate to `Xbookmark::Keystore::AuthConfig`, `Resolver`, and the selected platform/1Password backend.
- `backfill` and `sync` first process cached pending/retry rows from SQLite. Rows with cached `payload_json` can be enriched without X; uncached legacy retry rows and new bookmark discovery still need X.
- `sync` starts from the newest bookmark page and stops after a page with no new bookmarks; X `next_token` values are not treated as durable cursors between runs.
- `find` delegates to `Xbookmark::Qmd::Searcher`.
- `taxonomy audit` delegates to `Xbookmark::Taxonomy::Auditor`; `taxonomy rebuild` delegates to `Xbookmark::Taxonomy::Rebuilder`.
- `install` delegates to `Xbookmark::Scheduler::Factory` and, when installing for real, `Xbookmark::CodexConfig` and `Xbookmark::Qmd::Registrar`; `--dry-run` and `--uninstall` do not register QMD or change Codex config.
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
