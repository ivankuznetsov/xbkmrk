---
title: Dependencies
type: dependencies
source: git ls-files; Gemfile; Gemfile.lock; xbookmark.gemspec; README.md; lib/xbookmark/keystore/*.rb
created: 2026-05-14
updated: 2026-07-09
tags: [dependencies]
---

**TLDR**: `xbookmark` is a Ruby gem-style CLI with Ruby gems for CLI/config/state/HTTP/TOML auth routing and external tools for Codex, QMD, Whisper, credential stores, and native schedulers.

## Ruby Dependencies

The project contains:

- `Gemfile` using `gemspec`, plus development/test/check gems `minitest`, `mocha`, `webmock`, `rake`, `rubocop`, `rubocop-rails-omakase`, `brakeman`, and `bundler-audit`.
- `xbookmark.gemspec` with runtime dependencies:
  - `thor` for the CLI.
  - `dotenv` for env-file loading.
  - `sqlite3` for local state.
  - `faraday` and `faraday-retry` for X API and link fetching.
  - `oauth2` for OAuth 2.0 PKCE token exchange; the temporary local callback listener uses Ruby's standard `socket` library instead of WEBrick.
  - `nokogiri` for external link text extraction.
  - `down` for media downloads.
  - `json-schema` for validating Codex JSON output.
  - `tomlrb` for reading provider auth routing from `~/.config/xbookmark/auth.toml`.
  - `base64` and `ostruct`.
- The 2026-05-30 dependency commit added `tomlrb (~> 2.0)` as a runtime dependency and locked `tomlrb 2.0.4`; no development/test gem changed in that committed diff.
- Required Ruby version in the gemspec is `>= 3.1`.

## External Runtime Tools

The runtime shells out to external tools:

- `codex` for LLM enrichment via `codex exec --json`.
  - Bookmark-note enrichment always uses Codex. Separate author page summaries are opt-in with `XBOOKMARK_AUX_SUMMARIES=true` because they add extra Codex calls during backfill.
  - Setup/install cleanup edits `~/.codex/config.toml` or `$CODEX_HOME/config.toml` only to remove stale invalid top-level `service_tier` values that can break scheduled runs; valid speed modes are preserved.
- `qmd` for search collection registration, indexing, and querying.
- A whisper backend, detected from `WHISPER_BIN` or PATH candidates `whisper-cli`, `whisper-cpp`, `whisper`, and `faster-whisper`.
  - For whisper.cpp binaries, model aliases such as `base.en` resolve to `ggml-base.en.bin` under `WHISPER_MODEL_DIR`, the source checkout's `models/` directory next to the binary, or `./models`.
  - `ffmpeg` is required to extract audio from downloaded video media before whisper.cpp transcription.
  - `WHISPER_THREADS` optionally controls whisper.cpp CPU threads; blank defaults to up to 8 local CPU threads.
- Credential-store tools:
  - macOS uses the `security` CLI for login Keychain access.
  - Linux uses `secret-tool` when a D-Bus session is available, otherwise xbookmark falls back to a `0600` env file under `~/.config/xbookmark/.env`.
  - Provider auth routing also treats Linux libsecret as unavailable when `DBUS_SESSION_BUS_ADDRESS` is empty, even if `secret-tool` is on `PATH`, so routed lookups produce an actionable keychain-unavailable hint instead of hanging on D-Bus-less hosts.
  - Keychain/libsecret reads treat signal-killed backend commands as hard errors, not absent secrets. Libsecret deletes tolerate an already-absent secret so stale `auth.toml` routing can still be cleared.
  - The 1Password backend shells out to `op read --no-newline <op://...>` with a bounded runtime and child reaping; `AuthConfig` records provider routing and optional `op://` refs in `~/.config/xbookmark/auth.toml` with mode `0600`, but not secret values.
- System scheduler tools: `systemctl --user` and `loginctl` on Linux, and `launchctl` on macOS.

## External Services

- X API v2 for bookmarks and tweet details.
- Local OAuth callback server on loopback for PKCE login.
- Optional HTTP fetching of public external article links found in bookmarks, guarded by URL/IP safety checks.

## Contributor Checks

xbookmark mirrors Hive's baseline CI shape:

- `bundle exec rake test`
- `bundle exec rake coverage`
- `bundle exec rubocop --parallel --format github`
- `bundle exec brakeman --force --no-pager --quiet --format github --ignore-config config/brakeman.ignore`
- `bundle exec bundler-audit check --update`

The `coverage` rake task uses Ruby's built-in `Coverage` API to enforce 100%
line coverage for `bin/` and `lib/` without adding a new gem dependency.

The development/test bundle includes `minitest`, `mocha`, `webmock`, `rake`, `rubocop`,
`rubocop-rails-omakase`, `brakeman`, and `bundler-audit`.

Related: [[architecture]], [[commands]], [[api]], [[data-model]], [[gaps]].
