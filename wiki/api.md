---
title: API Surface
type: api
source: lib/xbookmark/x/auth.rb; lib/xbookmark/x/client.rb; lib/xbookmark/qmd/registrar.rb; lib/xbookmark/qmd/searcher.rb; README.md; .env.example
created: 2026-05-14
updated: 2026-07-09
tags: [api, x-api, oauth, cli]
---

**TLDR**: `xbookmark` has no web app routes; its external surface is a CLI, X API v2 calls, a temporary local OAuth callback, provider credential routing, and QMD registration/search/reindex subprocess calls.

## Scope

API facts are taken from the current branch and its README.

## HTTP Routes

There is no persistent HTTP server or application route table.

During `auth login`, `Xbookmark::X::Auth` starts a temporary WEBrick loopback server and mounts only `/callback`. The callback accepts the OAuth authorization code, validates the `state` parameter, and then shuts the server down.

## X OAuth Surface

- Authorization URL: `https://twitter.com/i/oauth2/authorize`.
- Token URL: `https://api.twitter.com/2/oauth2/token`.
- Scopes: `tweet.read`, `users.read`, `bookmark.read`, and `offline.access`.
- PKCE method: S256.
- The callback URI comes from `X_REDIRECT_URI`; `.env.example` uses `http://127.0.0.1:8765/callback`. If the env key is omitted, config falls back to the internal local port default.
- Refresh is implemented in `Xbookmark::X::Auth#refresh!` for the API client and exposed as `xbookmark auth refresh` so users can validate/rotate the saved refresh token without waiting for a sync run.
- Tokens are persisted by updating the configured env file with `0600` permissions.

## X API Client Surface

`Xbookmark::X::Client` calls X API v2 through Faraday:

- `GET /2/users/:user_id/bookmarks` for bookmark pages.
- `GET /2/tweets/:id` for a single tweet.
- `GET /2/tweets/search/recent` with `conversation_id:<id>` for conversation context.

Bookmark requests use 50-item pages and follow `meta.next_token`. Production testing on 2026-05-22 found that `max_results=100` returned only 98 IDs and no `next_token`, while `max_results=50` returned 4,745 unique IDs over 95 pages. Pagination tokens are used only within one traversal; incremental sync starts at the newest page and stops after reaching a page with no new bookmarks. Requests include tweet, user, media, and expansion fields defined in `Xbookmark::X::Client`. The client retries selected 5xx responses through Faraday, refreshes once on 401 when a refresh token is present, raises `RateLimited` on 429, and raises transient errors for other non-success responses.

## QMD Subprocess Surface

- Collection name is `bookmarks`.
- `Qmd::Registrar#registered?` invokes `qmd collection list` first and falls back to legacy `qmd list`. It requires an exact `bookmarks` field match and treats the old `<bookmark-wiki>/bookmarks` root as legacy rather than current registration.
- `Qmd::Registrar#register!` ensures the bookmark wiki root exists, invokes `qmd collection add <bookmark-wiki> --name bookmarks`, and treats that current command as already indexed.
- If the current registration command fails, the registrar falls back to legacy `qmd register --name bookmarks --path <path>` and then indexes with `qmd index --collection bookmarks`.
- `Qmd::Registrar#index!` invokes `qmd index --collection bookmarks`; if that indexing command fails, the registrar falls back once more to `qmd update` before warning and returning a failed status.
- `Qmd::Searcher` invokes `qmd query --collection bookmarks --types lex,vec --limit N --json QUERY`.
- The CLI currently prints numbered text results with score, path, and optional snippet.
- `sync` and `taxonomy rebuild --apply` reindex after generated wiki changes. Taxonomy rebuild records the QMD reindex status in its manifest rather than rolling back file repairs when search refresh fails.

## Codex Subprocess Surface

- `Enrich::Codex` invokes `codex exec --json` and parses JSONL event streams.
- Current Codex emits final model text under `item.completed` events with an `item.type` of `agent_message`; xbookmark unwraps the nested `item.text` JSON.
- Older model-message and plain JSON object output shapes remain accepted.

## Codex Config File Surface

- `Xbookmark::CodexConfig.default_path` reads `$CODEX_HOME/config.toml` when `CODEX_HOME` is set, otherwise `~/.codex/config.toml`.
- `xbookmark setup` and non-dry-run `xbookmark install` remove only stale invalid top-level `service_tier` values before the first TOML table. Project-scoped tables such as `[projects."/tmp/app"]` and valid speed modes are preserved.
- When the file is rewritten, xbookmark creates parent directories as needed, writes through an atomic temp-file replacement, and sets the config file mode to `0600`.

## Provider Credential Surface

- Provider names are parsed through `Xbookmark::Keystore::Provider` and limited to lowercase letters, digits, underscores, and hyphens, with path traversal rejected before any backend or TOML section is touched.
- `~/.config/xbookmark/auth.toml` stores provider routing only: backend names and optional `op://` refs, never secret values. The file is written with mode `0600`.
- `Xbookmark::Keystore::Resolver` is the runtime provider-key entry point. CI/env-forced mode reads canonical `XBOOKMARK_<PROVIDER>_KEY` environment variables; normal mode prefers `auth.toml` routing to 1Password or the platform keychain, then falls back to environment variables.
- `xbookmark auth bind PROVIDER OP_REF` validates the 1Password reference shape and smoke-checks `op read` when available. `xbookmark auth login PROVIDER` stores an interactively entered key in the platform keychain without accepting it on argv.
- `xbookmark auth show PROVIDER` prints the resolved credential for diagnostics and scripts. Use `auth list` when the value must remain hidden.

## Public Contract Notes

The current README documents the current CLI only. Deferred commands and flags are cataloged in [[commands]] so they are not accidentally exposed in setup docs before implementation.

Related: [[commands]], [[architecture]], [[dependencies]], [[gaps]].
