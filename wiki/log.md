# Wiki Changelog

Append-only log of meaningful wiki updates.

## [2026-05-14T16:53:27Z] bootstrap

**Action:** Managed llm-wiki bootstrap from codebase and Hive registry.
**Pages created:** wiki/active-areas.md, wiki/architecture.md, wiki/decisions.md, wiki/dependencies.md, wiki/gaps.md, wiki/index.md, wiki/log.md
**Pages updated:** wiki/index.md, wiki/log.md, wiki/gaps.md, .llm-wiki/config.json, AGENTS.md, CLAUDE.md, .claude/settings.json
**QMD:** qmd missing
**Scheduler:** files written; systemctl enable failed for llm-wiki-xbookmark-e08e1f34.timer
**Post-commit hook:** /home/asterio/Dev/xbookmark/.git/hooks/post-commit
**Source:** Codebase read + git history

## [2026-05-14T17:07:29Z] refresh

**Action:** Refreshed wiki after reading `.llm-wiki/config.json`, `AGENTS.md`, existing wiki pages, recent log entries, configured main wiki path, default main wiki paths, git history, Hive state, and worktree source files.
**Pages created:** wiki/commands.md, wiki/data-model.md
**Pages updated:** wiki/architecture.md, wiki/dependencies.md, wiki/decisions.md, wiki/active-areas.md, wiki/gaps.md, wiki/index.md, wiki/log.md
**Main wiki:** searched `/home/asterio/wikis/master/wiki`; no xbookmark-specific page found. Other requested default main wiki paths did not exist.
**QMD:** qmd available; `qmd search` used during refresh.
**Source:** `main` git history, `.hive-state/config.yml`, Hive stage files, `git worktree list`, implementation worktree `i-want-to-create-a-260504-1253`, README review worktree `create-proper-readme-md-for-260513-2ba1`

## [2026-05-14T17:26:52Z] llm-wiki validation

**Action:** Validated managed llm-wiki bootstrap and scheduled maintenance after Hive registry bootstrap.
**Headless agent:** Codex (`.llm-wiki/config.json` has `headless_agent: "codex"`).
**Context:** `AGENTS.md` and `CLAUDE.md` contain the managed LLM WIKI block; Claude `SessionStart` prints `wiki/index.md` and recent `wiki/log.md`.
**QMD:** `qmd 2.1.0` collection update, embed, and `qmd search` succeeded for this collection after the scheduled refresh test. QMD attempted GPU first and fell back to CPU because Vulkan headers are missing.
**Scheduler:** `llm-wiki-xbookmark-e08e1f34.timer` is enabled and active under `systemctl --user`; next run is scheduled for 2026-05-15 18:03:41 BST.
**Maintenance scripts:** `.llm-wiki/refresh-wiki.sh` and `.llm-wiki/post-commit-refresh.sh` use bounded Codex and qmd timeouts and tell headless Codex not to run `qmd update` or `qmd embed` itself.
**Source:** `systemctl --user list-timers`, `qmd update`, `qmd embed`, and collection-scoped `qmd search`.

## [2026-05-14T19:37:29Z] README review fix

**Action:** Restored wiki context into the README review worktree and updated the command mismatch note after the README changed `auth status` to read-only with an explicit `auth refresh`.
**Pages updated:** wiki/commands.md, wiki/log.md
**Source:** README review worktree fix pass 04.

## [2026-05-14T19:43:18Z] command-api refresh

**Action:** Refreshed command and API surface coverage after commit `8e6ad0e` expanded README contracts for auth, config discovery, backfill idempotency, QMD find behavior, scheduling, credential paths, Whisper models, and contributor checks.
**Pages created:** wiki/api.md
**Pages updated:** wiki/commands.md, wiki/architecture.md, wiki/decisions.md, wiki/dependencies.md, wiki/active-areas.md, wiki/gaps.md, wiki/index.md, wiki/log.md
**Main wiki:** searched `/home/asterio/wikis/master/wiki`; no xbookmark-specific page found. Read relevant OAuth, command execution, and SSRF notes from master wiki context.
**QMD:** not run; the post-commit wrapper owns bounded qmd maintenance for this refresh.
**Source:** latest committed diff `8e6ad0e`, README branch `README.md`, `.env.example`, `.gitignore`, Hive review task file, implementation branch `bin/xbookmark`, `lib/xbookmark/cli*.rb`, `lib/xbookmark/config.rb`, `lib/xbookmark/x/auth.rb`, `lib/xbookmark/x/client.rb`, `lib/xbookmark/qmd/searcher.rb`, scheduler files, and gem manifests.

## [2026-05-22T13:18:15Z] setup-contract refresh

**Action:** Updated the project wiki after PR review clarified that xbookmark is unreleased and new setups should follow the implemented CLI only.
**Pages updated:** wiki/commands.md, wiki/gaps.md, wiki/decisions.md, wiki/data-model.md, wiki/index.md, wiki/api.md, wiki/architecture.md, wiki/dependencies.md, wiki/active-areas.md, wiki/log.md
**Decision:** Runtime output is a standalone bookmark wiki configured by `XBOOKMARK_WIKI_PATH`; this repository's `wiki/` remains the project LLM wiki. The `xbookmark-wiki` default does not need migration from `xbookmark-vault` before release.
**Source:** `README.md`, `.env.example`, `lib/xbookmark/config.rb`, `lib/xbookmark/cli.rb`, `lib/xbookmark/cli/*.rb`, scheduler implementation, and review findings for PR #7.

## [2026-05-22T13:36:38Z] ci-checks refresh

**Action:** Added Hive-style CI checks for xbookmark and updated contributor docs.
**Pages updated:** wiki/dependencies.md, wiki/log.md
**Decision:** CI runs the coverage Rake task, RuboCop with the 37signals omakase base, Brakeman, and bundler-audit. The local RuboCop config keeps xbookmark's existing array-bracket style to avoid a broad mechanical rewrite.
**Source:** Hive `.github/workflows/ci.yml`, Hive Dependabot/PR template, xbookmark Gemfile, `.rubocop.yml`, `.github/workflows/ci.yml`, and local check outputs.

## [2026-05-22T15:23:06Z] default scheduler setup refresh

**Action:** Made daily scheduler installation part of the default setup contract and aligned QMD registration with the installed `qmd collection add` CLI while preserving legacy command fallback.
**Pages updated:** wiki/commands.md, wiki/gaps.md, wiki/decisions.md, wiki/active-areas.md, wiki/log.md
**Source:** `README.md`, `lib/xbookmark/qmd/registrar.rb`, `spec/xbookmark/qmd/registrar_spec.rb`, production install output.

## [2026-05-22T15:28:29Z] command-api coverage refresh

**Action:** Refreshed command/API coverage after commit `8c5833f` touched README setup flow and QMD registrar behavior; also corrected stale branch/main wiki context.
**Pages updated:** wiki/api.md, wiki/commands.md, wiki/architecture.md, wiki/active-areas.md, wiki/decisions.md, wiki/data-model.md, wiki/dependencies.md, wiki/gaps.md, wiki/index.md, wiki/log.md
**Main wiki:** searched `/home/asterio/wikis/master/wiki`; no xbookmark/QMD/scheduler-specific page found. Other default main wiki paths did not exist.
**QMD:** `qmd search` was read-only and returned stale indexed snippets; did not run `qmd update` or `qmd embed` because the post-commit wrapper owns bounded qmd maintenance.
**Gap recorded:** `.env.example` still references `--port`, but the implemented auth command uses `X_REDIRECT_URI` and has no `auth login --port` flag.
**Source:** `AGENTS.md`, `.llm-wiki/config.json`, wiki core pages and recent log entries, latest committed diff `8c5833f`, `README.md`, `.env.example`, `lib/xbookmark/cli.rb`, `lib/xbookmark/cli/auth.rb`, `lib/xbookmark/cli/install.rb`, `lib/xbookmark/x/auth.rb`, `lib/xbookmark/qmd/registrar.rb`, `lib/xbookmark/qmd/searcher.rb`, scheduler files, `spec/readme_contract_spec.rb`, `spec/xbookmark/qmd/registrar_spec.rb`, and `main..HEAD` diff.

## [2026-05-22T15:40:00Z] linger setup refresh

**Action:** Added Linux systemd linger enablement to scheduler install so default setup can run daily timers after logout, and fixed `.env.example` to avoid the nonexistent `--port` option.
**Pages updated:** wiki/commands.md, wiki/architecture.md, wiki/active-areas.md, wiki/decisions.md, wiki/dependencies.md, wiki/gaps.md, wiki/log.md
**Source:** `README.md`, `.env.example`, `lib/xbookmark/scheduler/systemd.rb`, `spec/xbookmark/scheduler/systemd_spec.rb`, `spec/readme_contract_spec.rb`.

## [2026-05-22T15:55:00Z] codex-jsonl live setup fix

**Action:** Updated Codex enrichment parsing after live production backfill showed current `codex exec --json` emits final JSON under `item.completed` agent-message events.
**Pages updated:** wiki/api.md, wiki/active-areas.md, wiki/gaps.md, wiki/log.md
**Source:** Live `bin/xbookmark backfill --limit 100` failure, `lib/xbookmark/enrich/codex.rb`, `spec/xbookmark/enrich/codex_spec.rb`.

## [2026-05-22T16:10:00Z] large media download setup fix

**Action:** Removed the default 200 MB media download cap after live production backfill hit `Down::TooLarge` on X video variants.
**Pages updated:** wiki/architecture.md, wiki/active-areas.md, wiki/gaps.md, wiki/log.md
**Source:** Live `bin/xbookmark backfill --limit 100` failure, `lib/xbookmark/media/downloader.rb`, `spec/xbookmark/media/downloader_spec.rb`.

## [2026-05-22T17:35:00Z] whisper model setup fix

**Action:** Fixed whisper.cpp model resolution so `WHISPER_MODEL=base.en` resolves to a local `ggml-base.en.bin` file and documented the model download step in setup instructions.
**Pages updated:** wiki/active-areas.md, wiki/dependencies.md, wiki/log.md
**Production check:** Downloaded `ggml-base.en.bin` into the production whisper.cpp checkout and reran all Whisper-failed media rows; state ended with 31 bookmarks done and zero Whisper failures.
**Source:** Live production resync failures, `lib/xbookmark/transcribe/whisper.rb`, `spec/xbookmark/transcribe/whisper_spec.rb`, `README.md`.

## [2026-05-22T18:15:00Z] backfill speed path

**Action:** Removed the planning Codex call from bookmark enrichment, filtered out X media/status URLs from article fetching, and made separate aux-page LLM summaries opt-in.
**Pages updated:** wiki/architecture.md, wiki/data-model.md, wiki/active-areas.md, wiki/dependencies.md, wiki/log.md
**Decision:** Bookmark notes remain enriched and link to author/topic/entity/thread pages. Aux landing pages are still written for Obsidian graph/backlinks, but their own summaries are disabled by default so 100+ bookmark backfills do not spend most runtime on per-slug summaries.
**Source:** Live 31-bookmark production wiki had 302 aux pages and 300 aux summaries, far exceeding the bookmark-note work.

## [2026-05-22T19:55:00Z] whisper media rerun fix

**Action:** Fixed whisper.cpp transcription for downloaded X videos by extracting audio through `ffmpeg`, adding duration-aware timeouts for long media, using more CPU threads by default, and treating no-audio videos as empty transcripts instead of retry failures.
**Pages updated:** wiki/architecture.md, wiki/dependencies.md, wiki/active-areas.md, wiki/log.md
**Production check:** Reran Whisper over 20 production MP4 files. Eighteen produced non-empty transcript sidecars and were injected into bookmark markdown; two MP4s had no audio stream and cleanly produced empty transcript sidecars.
**Source:** Live production media rerun, `lib/xbookmark/transcribe/whisper.rb`, `lib/xbookmark/cli/doctor.rb`, `spec/xbookmark/transcribe/whisper_spec.rb`, `README.md`, `.env.example`.

## [2026-05-22T20:40:00Z] find limit enforcement

**Action:** Added an xbookmark-side cap to QMD search results after production `bin/xbookmark find ... --limit 3` returned four hits from the installed QMD.
**Pages updated:** wiki/commands.md, wiki/log.md
**Source:** Live production `bin/xbookmark find Transcript --limit 3`, `lib/xbookmark/qmd/searcher.rb`, `spec/xbookmark/qmd/searcher_spec.rb`.

## [2026-05-22T21:05:00Z] production learning capture

**Action:** Consolidated the most important live production setup/backfill lessons into a dedicated wiki page and added the user-facing X pagination/idempotency notes to the README.
**Pages created:** wiki/live-production-learnings.md
**Pages updated:** README.md, wiki/index.md, wiki/decisions.md, wiki/gaps.md, wiki/active-areas.md, wiki/log.md
**Source:** Production install/backfill/transcription/search/scheduler verification, X API pagination probes, bookmark folder probe, duplicate audit, PRs #10-#12.

## [2026-05-22T22:05:00Z] bookmark page-size correction

**Action:** Corrected the X bookmark pagination finding: production `max_results=100` returned 98 IDs and no token, but `max_results=50` returned 4,745 unique IDs over 95 pages. xbookmark should use 50-item bookmark pages.
**Pages updated:** README.md, wiki/api.md, wiki/active-areas.md, wiki/commands.md, wiki/decisions.md, wiki/gaps.md, wiki/live-production-learnings.md, wiki/log.md
**Source:** Read-only production X API probes from `/home/asterio/Dev/xbookmark.install/xbookmark`.

## [2026-05-22T22:35:00Z] 100-percent coverage gate

**Action:** Added real behavioral tests across CLI dispatch, config/path discovery, OAuth, X API retries/errors, QMD, scheduler install/uninstall/status, media/transcription, rendering, sync pipeline/runner, and the executable wrapper. Added `bundle exec rake coverage` using Ruby's built-in `Coverage` API to enforce 100% line coverage over `bin/` and `lib/`.
**Pages updated:** wiki/dependencies.md, wiki/log.md
**Bug fixed:** `LinkFetcher#resolve` now fails closed when DNS resolution raises after a hostname parse miss.
**Verification:** After merging into current `main`, `bundle exec rake coverage` passed with 299 examples at 100.00% (2297/2297), and `bundle exec rubocop` passed with no offenses.
**Source:** `Rakefile`, `bin/xbookmark`, `lib/xbookmark/enrich/link_fetcher.rb`, and expanded specs under `spec/`.

## [2026-05-25T10:55:00Z] codex service tier setup fix

**Action:** Added setup/install cleanup for stale invalid top-level Codex `service_tier` values after production wiki maintenance failed on `service_tier = "default"` and docs review showed setup should not force Codex speed modes.
**Pages updated:** README.md, wiki/decisions.md, wiki/log.md
**Source:** `lib/xbookmark/codex_config.rb`, `lib/xbookmark/cli/setup.rb`, `lib/xbookmark/cli/install.rb`, `test/xbookmark/codex_config_test.rb`, `test/xbookmark/cli/setup_test.rb`, `test/xbookmark/cli_test.rb`, `README.md`.

## [2026-05-25T10:56:00Z] llm-wiki refresh

**Action:** Refreshed project wiki pages from current config, recent log entries, cross-project wiki search, recent git history, coverage work, and Codex service-tier setup changes.
**Pages updated:** wiki/architecture.md, wiki/api.md, wiki/commands.md, wiki/data-model.md, wiki/dependencies.md, wiki/active-areas.md, wiki/decisions.md, wiki/live-production-learnings.md, wiki/gaps.md, wiki/index.md, wiki/log.md
**Main wiki:** searched `/home/asterio/wikis/master/wiki`; no xbookmark-specific page found. `~/wikis/main/wiki`, `../wikis/master/wiki`, and `../wikis/main/wiki` did not exist.
**QMD:** review follow-up ran bounded `qmd search` queries for Codex service-tier and large-prompt terms; no indexed hits were returned. This refresh intentionally avoided `qmd update` and `qmd embed` because the wrapper script owns bounded qmd maintenance.
**Source:** `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, `wiki/index.md`, `wiki/gaps.md`, recent `wiki/log.md`, `git log --name-status`, `git status --short`, `Rakefile`, `lib/xbookmark/codex_config.rb`, `lib/xbookmark/cli/setup.rb`, `lib/xbookmark/cli/install.rb`, `lib/xbookmark/enrich/link_fetcher.rb`, and related specs.

## [2026-05-25T11:40:00Z] codex large prompt fix

**Action:** Changed Codex enrichment invocation to pass prompts over stdin instead of argv after production backfill hit `Errno::E2BIG: Argument list too long - codex` on a large bookmark prompt.
**Pages updated:** wiki/decisions.md, wiki/live-production-learnings.md, wiki/log.md
**Source:** Live production backfill log, `lib/xbookmark/enrich/codex.rb`, `test/xbookmark/enrich/codex_test.rb`, `test/xbookmark/enrich/orchestrator_test.rb`, `test/integration/v1_acceptance_test.rb`.

## [2026-05-25T00:00:00Z] minitest fixture migration

**Action:** Migrated the RSpec suite to Minitest, replaced RSpec mocks with Mocha, moved tests from `spec/` to `test/`, and added JSON fixtures for X bookmark API pages.
**Pages updated:** README.md, wiki/dependencies.md, wiki/gaps.md, wiki/log.md
**Decision:** Contributor and CI test commands now use `bundle exec rake test`, while `bundle exec rake coverage` remains the enforced 100% line coverage gate for `bin/` and `lib/`.
**Verification:** `bundle exec rake coverage` passed with 301 runs, 1053 assertions, and 100.00% coverage (2297/2297).
**Source:** `Gemfile`, `Rakefile`, `.github/workflows/ci.yml`, `test/`, and `test/fixtures/x/`.

## [2026-06-14T22:37:30Z] source-blocked scheduler hardening

**Action:** Added scheduler-degraded sync semantics and SQLite source-payload caching so source-only X auth/rate/transport outages do not block local cleanup, QMD maintenance, or cached retry/enrichment work.
**Pages updated:** README.md, wiki/architecture.md, wiki/commands.md, wiki/data-model.md, wiki/decisions.md, wiki/log.md
**Decision:** Scheduled source-only failures report `source blocked`, exit successfully when no local bookmark work failed, and do not stamp `last_sync_finished_at`; manual sync still exits non-zero on source errors. Schema version 2 adds `bookmarks.payload_json` and repairs stamped databases missing the column.
**Source:** PR #47, `lib/xbookmark/sync/runner.rb`, `lib/xbookmark/state/migrations.rb`, `lib/xbookmark/state/store.rb`, `lib/xbookmark/x/client.rb`, `lib/xbookmark/x/auth.rb`, `lib/xbookmark/qmd/registrar.rb`, and related tests.

## [2026-06-14T22:48:25Z] release metadata 0.2.1

**Action:** Prepared patch release metadata for xbookmark 0.2.1 after the source-blocked scheduler hardening merged.
**Pages updated:** wiki/log.md
**Decision:** Use a patch release because the installable change is a daemon reliability/auth-degraded behavior fix over 0.2.0, not a new feature-line release.
**Source:** `lib/xbookmark/version.rb`, `CHANGELOG.md`, `README.md`, and PR #47.

## [2026-06-14T22:58:00Z] macOS release packaging fix

**Action:** Updated the release workflow after tag `v0.2.1` showed that `brew install tebako` no longer resolves on GitHub macOS runners.
**Pages updated:** wiki/log.md
**Decision:** Install Homebrew prerequisites explicitly on macOS and install Tebako through `gem install tebako --no-document`, matching current Tebako installation guidance.
**Source:** GitHub Actions run 27514621594, `.github/workflows/release.yml`, `test/release_workflow_test.rb`, and `packaging/RELEASE.md`.

## [2026-06-14T23:03:30Z] Tebako entry-point release fix

**Action:** Fixed the release workflow after Tebako packaged the gem executable under `bin/xbookmark` and the previous `--entry-point=bin/xbookmark` setting resolved to `bin/bin/xbookmark`.
**Pages updated:** wiki/log.md
**Decision:** Use `--entry-point=xbookmark` for release builds and keep the Tebako config aligned with that executable name.
**Source:** GitHub Actions run 27514713761, `.github/workflows/release.yml`, `packaging/tebako/xbookmark.yml`, and `test/release_workflow_test.rb`.

## [2026-06-14T23:21:00Z] Homebrew smoke tap fix

**Action:** Updated the release workflow after Homebrew rejected installing the rendered formula from a direct local file path during smoke testing.
**Pages updated:** wiki/log.md
**Decision:** Create a temporary local tap for the Homebrew smoke test, copy the rendered formula into that tap, and install `local/xbookmark-test/xbookmark`.
**Source:** GitHub Actions run 27514897686, `.github/workflows/release.yml`, and `test/release_workflow_test.rb`.

## [2026-06-14T23:33:30Z] optional release publisher guards

**Action:** Added configuration guards after the `v0.2.1` release was promoted successfully but the optional Homebrew tap and AUR publisher jobs failed because their deploy secrets/repositories were not configured.
**Pages updated:** wiki/log.md
**Decision:** Keep GitHub release assets and install-channel smoke tests as the hard release gate; skip optional external package publishers with a notice when their deployment secrets are absent.
**Source:** GitHub Actions run 27515320403, `.github/workflows/release.yml`, `packaging/RELEASE.md`, and `test/release_workflow_test.rb`.

## [2026-06-15T00:05:00Z] auth refresh diagnostics

**Action:** Added explicit expired-token handling to `auth status` and exposed `auth refresh` so users can validate and rotate saved X OAuth refresh tokens without waiting for a sync run.
**Pages updated:** README.md, wiki/commands.md, wiki/active-areas.md, wiki/api.md, wiki/gaps.md, wiki/log.md
**Decision:** Treat an expired access token as a non-zero `auth status` result with the next actionable command, while `auth refresh` reports X refresh-token rejection directly and points users at `auth login`.
**Source:** `lib/xbookmark/cli/auth.rb`, `test/xbookmark/cli_test.rb`, `README.md`, and production token-expiry investigation.

## [2026-06-15T00:23:00Z] auth refresh review hardening

**Action:** Hardened `auth refresh` after code review by redacting token-like values, bounding token endpoint timeouts, distinguishing transient refresh outages from permanent reauthorization failures, and validating successful token responses before writing them.
**Pages updated:** README.md, wiki/commands.md, wiki/active-areas.md, wiki/api.md, wiki/log.md
**Decision:** Keep invalid/missing refresh tokens as exit 1 with an `auth login` hint, but report transport/429/5xx refresh failures as retryable exit 2; never persist a refresh response until it contains a non-empty access token and no OAuth error body.
**Source:** `lib/xbookmark/x/auth.rb`, `lib/xbookmark/cli/auth.rb`, `test/xbookmark/x/auth_test.rb`, `test/xbookmark/cli_test.rb`, and PR #53 code review findings.

## [2026-06-15T00:58:00Z] release metadata 0.2.2

**Action:** Prepared patch release metadata for xbookmark 0.2.2 after the X auth diagnostics and token refresh hardening merged.
**Pages updated:** CHANGELOG.md, lib/xbookmark/version.rb, wiki/log.md
**Decision:** Use a patch release because the installable change improves daemon/auth recovery diagnostics and token safety over 0.2.1 without changing the bookmark data model.
**Source:** `lib/xbookmark/version.rb`, `CHANGELOG.md`, and PR #53.

## [2026-06-15T01:24:00Z] auth login timeout diagnostics

**Action:** Caught `AuthError` from `auth login` and normalized token-exchange transport/malformed-response failures so OAuth callback timeouts and login failures print concise recovery guidance instead of a Ruby stack trace.
**Pages updated:** CHANGELOG.md, lib/xbookmark/version.rb, wiki/log.md
**Decision:** Prepare xbookmark 0.2.3 because the just-tested OAuth login flow still had user-facing failure output that should be in the installable build.
**Source:** `lib/xbookmark/cli/auth.rb`, `lib/xbookmark/x/auth.rb`, `test/xbookmark/cli_test.rb`, `test/xbookmark/x/auth_test.rb`, and the timed-out production OAuth login attempt.

## [2026-06-15T09:36:00Z] exhausted retry report accounting

**Action:** Fixed sync report accounting after a live production sync imported 79 bookmarks but printed `failed 1, retrying next run` even though the only failed row had crossed into `permanent_error`.
**Pages updated:** wiki/data-model.md, wiki/log.md
**Decision:** Have `Store.record_failure` return the final stored status and let `Sync::Runner` count an exhausted retry as a permanent error immediately, keeping CLI output aligned with SQLite state.
**Source:** Production sync ending at `2026-06-15T09:23:28Z`, `lib/xbookmark/state/store.rb`, `lib/xbookmark/sync/runner.rb`, `test/xbookmark/state/store_test.rb`, and `test/xbookmark/sync/runner_test.rb`.

## [2026-06-15T09:58:00Z] image enrichment fallback

**Action:** Added a text-only fallback after a production image bookmark repeatedly made `codex exec --json` return only wrapper events and no model payload.
**Pages updated:** wiki/architecture.md, wiki/log.md
**Decision:** Treat transient image-Codex failures as degraded bookmark enrichment: rerun the final prompt without images, mark the result partial, and only keep failing when text-only Codex also fails.
**Source:** Production resync of tweet `2013285563386704077`, `lib/xbookmark/enrich/orchestrator.rb`, and `test/xbookmark/enrich/orchestrator_test.rb`.

## [2026-06-15T10:07:00Z] release metadata 0.2.4

**Action:** Prepared patch release metadata for xbookmark 0.2.4 after the exhausted-retry accounting and image-enrichment fallback fixes.
**Pages updated:** CHANGELOG.md, lib/xbookmark/version.rb, Gemfile.lock, wiki/log.md
**Decision:** Use a patch release because the installable changes improve daemon reliability and bookmark-enrichment recovery without changing the data model.
**Source:** Code review findings on branch `fix/sync-enrichment-resilience`, `lib/xbookmark/version.rb`, `CHANGELOG.md`, and `Gemfile.lock`.

## [2026-06-15T12:00:00Z] graph taxonomy reshape

**Action:** Implemented readable bookmark source-note filenames, canonical concept pages, concept candidate enrichment, offline taxonomy audit/rebuild, graph-health reports, and scheduler-local taxonomy maintenance.
**Pages updated:** README.md, CHANGELOG.md, wiki/architecture.md, wiki/data-model.md, wiki/commands.md, wiki/decisions.md, wiki/dependencies.md, wiki/active-areas.md, wiki/log.md
**Decision:** Use concept pages plus broader wikilinks as the Obsidian graph hierarchy, keep nested tags as facets, suppress singleton thread pages, and keep taxonomy cleanup independent of live X API access.
**Source:** `lib/xbookmark/taxonomy/*`, `lib/xbookmark/render/bookmark_renderer.rb`, `lib/xbookmark/enrich/orchestrator.rb`, `lib/xbookmark/sync/pipeline.rb`, `lib/xbookmark/sync/runner.rb`, `lib/xbookmark/qmd/registrar.rb`, and related tests.

## [2026-06-15T16:49:06Z] command and API surface refresh

**Action:** Refreshed command/API wiki coverage after inspecting the taxonomy branch diff and CLI/QMD/taxonomy handlers.
**Pages updated:** wiki/index.md, wiki/architecture.md, wiki/active-areas.md, wiki/commands.md, wiki/api.md, wiki/gaps.md, wiki/log.md
**Decision:** Document `doctor --fix`, correct QMD registration to the bookmark wiki root, record taxonomy/sync reindex behavior, and align coverage wording with the current Minitest suite. No `qmd update` or `qmd embed` was run during this refresh.
**Source:** `origin/main..origin/feat/wiki-graph-taxonomy` at `c83d53c`, `bin/xbookmark`, `lib/xbookmark/cli.rb`, `lib/xbookmark/cli/doctor.rb`, `lib/xbookmark/cli/taxonomy.rb`, `lib/xbookmark/qmd/registrar.rb`, `lib/xbookmark/taxonomy/rebuilder.rb`, `README.md`, and `test/readme_contract_test.rb`.

## [2026-06-15T17:31:57Z] taxonomy maintenance review fixes

**Action:** Hardened taxonomy maintenance after PR review by making rebuilds forward-only, migrating real numeric thread pages, preserving enrichment aliases/parents, using run-level registry/thread caches, wiring scheduled curator maintenance, and allowing offline taxonomy config without X credentials.
**Pages updated:** README.md, wiki/architecture.md, wiki/commands.md, wiki/data-model.md, wiki/decisions.md, wiki/log.md
**Decision:** Snapshots are manual recovery/audit evidence rather than automatic rollback; local cleanup, curator fallback, QMD maintenance, and cached enrichment should keep running when live X or Codex is unavailable.
**Source:** PR #57 code review findings, `lib/xbookmark/taxonomy/rebuilder.rb`, `lib/xbookmark/taxonomy/curator.rb`, `lib/xbookmark/sync/pipeline.rb`, `lib/xbookmark/sync/runner.rb`, `lib/xbookmark/config.rb`, `lib/xbookmark/state/store.rb`, and related tests.

## [2026-06-15T17:46:38Z] concept page materialization verification

**Action:** Fixed post-merge local verification gap where taxonomy rebuild cleaned numeric source/thread nodes but left persisted concepts only in SQLite and rendered no `concepts/*.md` pages.
**Pages updated:** README.md, wiki/architecture.md, wiki/commands.md, wiki/data-model.md, wiki/log.md
**Decision:** `taxonomy rebuild --apply` now materializes concept pages and `concepts/index.md` from local concept state even when no path/thread repair is pending; legacy topic/entity imports receive broad `topics`/`entities` parents so the graph has hierarchy.
**Source:** Local run against `/home/asterio/xbookmark-wiki` after PR #57 merge, `lib/xbookmark/taxonomy/rebuilder.rb`, and `test/xbookmark/taxonomy/rebuilder_test.rb`.

## [2026-06-15T17:52:41Z] bounded scheduled taxonomy curation

**Action:** Fixed forced local scheduler verification hanging in Codex after the legacy wiki exposed 9k persisted concepts.
**Pages updated:** wiki/architecture.md, wiki/log.md
**Decision:** Scheduled taxonomy curation processes a bounded batch of persisted concepts per maintenance run instead of sending the entire local concept corpus to one Codex call.
**Source:** Forced `XBOOKMARK_MIN_RUN_INTERVAL_HOURS=0 bin/xbookmark sync --from-scheduler` run, `lib/xbookmark/sync/runner.rb`, and `test/xbookmark/sync/runner_test.rb`.

## [2026-06-15T18:12:00Z] topic-derived thread labels

**Action:** Fixed post-merge local verification gap where real multi-bookmark thread pages still rendered as `thread-<conversation-id>` graph nodes.
**Pages updated:** wiki/architecture.md, wiki/log.md
**Decision:** Future thread pages and taxonomy rebuild migrations derive their leading slug and wikilink label from cached local tweet text, falling back to rendered bookmark summaries, while retaining the conversation ID suffix for stable mapping; rebuilds repair existing placeholder thread pages without live X access.
**Source:** Local vault spot-check after PR #59 merge, `lib/xbookmark/sync/thread_index.rb`, `lib/xbookmark/taxonomy/rebuilder.rb`, and related tests.

## [2026-06-15T18:20:00Z] scheduled curation timeout

**Action:** Fixed forced scheduler verification still spending minutes inside a single Codex taxonomy-curation call.
**Pages updated:** wiki/architecture.md, wiki/log.md
**Decision:** Scheduled taxonomy curation is both batch-bounded and LLM-time-bounded; if Codex is too slow, the curator falls back to deterministic local rules so the daemon exits cleanly.
**Source:** Forced `XBOOKMARK_MIN_RUN_INTERVAL_HOURS=0 bin/xbookmark sync --from-scheduler` run, `lib/xbookmark/sync/runner.rb`, `lib/xbookmark/taxonomy/curator.rb`, and `test/xbookmark/sync/runner_test.rb`.

## [2026-06-15T19:35:00Z] explicit topic post lists

**Action:** Fixed Obsidian browsing gap where opening a concept/topic page required using the Backlinks panel to find matching bookmark posts.
**Pages updated:** README.md, wiki/architecture.md, wiki/data-model.md, wiki/log.md
**Decision:** Generated concept pages and legacy topic/entity pages include explicit `## Posts` lists built from local bookmark frontmatter. Concept pages inherit posts from narrower child concepts through `broader`, so broad concepts are useful browsing entry points.
**Source:** Local vault inspection of legacy `topics/` and `entities/` pages, `lib/xbookmark/render/concept_page.rb`, `lib/xbookmark/render/aux_page.rb`, `lib/xbookmark/taxonomy/rebuilder.rb`, and related tests.

## [2026-06-15T20:07:01Z] legacy taxonomy graph duplicate cleanup

**Action:** Fixed Obsidian graph duplicate labels caused by legacy `topics/` and `entities/` pages coexisting with canonical `concepts/` pages and author pages.
**Pages updated:** README.md, wiki/architecture.md, wiki/data-model.md, wiki/log.md
**Decision:** Taxonomy rebuild now rewrites legacy source-note topic/entity frontmatter and wikilinks into canonical concepts, prunes legacy topic/entity landing pages, suppresses author-handle concepts that duplicate author pages, and avoids rendering generic `topics`/`entities` concept roots as graph hubs.
**Source:** Local Obsidian graph inspection showing repeated `geiger-capital` nodes, `lib/xbookmark/taxonomy/rebuilder.rb`, `lib/xbookmark/render/concept_page.rb`, `lib/xbookmark/sync/pipeline.rb`, and related tests.

## [2026-06-15T21:30:00Z] structured-data: titles, Properties, rollback-safe curation

**Action:** Made generated data more structured and the scheduled curation rollback-safe (plan `docs/plans/2026-06-15-002-feat-structured-wiki-data-plan.md`, units U1–U6 on branch `feat/taxonomy-rollback-safety`).
**Pages updated:** README.md, CHANGELOG.md, wiki/data-model.md, wiki/log.md
**Decision:** Enrichment emits a concise `title` (drives filenames/labels). Bookmark frontmatter is schema-2 Obsidian Properties — typed dates, kept `tags`, bare `concepts` slugs; the dead `facets` key is dropped. Concept pages carry one closed semantic `kind` and no synthetic `topics`/`entities` broader (the rebuilder no longer re-seeds them). `taxonomy rebuild --apply` migrates existing notes to schema 2 offline; existing readable filenames are not renamed (only new notes get title-based names — full rename deferred). Scheduled curation writes are atomic, graph-health fails on surviving legacy pages, and snapshots are retained to the most recent few.
**Source:** `lib/xbookmark/enrich/orchestrator.rb`, `lib/xbookmark/render/{path_builder,bookmark_renderer,concept_page,concept_index}.rb`, `lib/xbookmark/taxonomy/{concept,curator,rebuilder,auditor,graph_health_report}.rb`, `lib/xbookmark/state/store.rb`, and their tests.

## [2026-06-15T22:30:00Z] offline note-source re-enrichment

**Action:** Added `xbookmark reenrich [--limit N]` to re-run the current enrichment contract over existing notes without re-fetching from X (branch `feat/offline-note-reenrich`).
**Pages updated:** CHANGELOG.md, wiki/commands.md, wiki/log.md
**Decision:** Re-enrichment sources from the note, not X. Only 157/1377 production notes still have a cached X payload, and many tweets (2021–2025) are deleted, so re-fetching would be lossy and rate-limited. `Enrich::NoteSource` reverses `BookmarkRenderer#body_for` to reconstruct the original tweet text + captions + transcripts; 1185/1220 payload-less notes carry real original text, the other 35 fall back to the (faithful) summary. `Orchestrator#enrich` gained a `vision:` override so reused captions feed the model as text (no fresh vision pass). `Pipeline#process_offline` skips download/transcribe/move and rewrites in place. `Sync::Reenricher` is resumable (skips current-schema notes) and resets concept evidence on a fresh full run so additive upserts don't double-count.
**Source:** `lib/xbookmark/enrich/note_source.rb`, `lib/xbookmark/enrich/orchestrator.rb`, `lib/xbookmark/sync/{pipeline,reenricher}.rb`, `lib/xbookmark/state/store.rb`, `lib/xbookmark/cli{,/sync}.rb`, and their tests. Piloted on production data: concise titles + typed concepts.

## [2026-07-09T11:15:00Z] provider secret routing rebase refresh

**Action:** Refreshed wiki coverage while rebasing PR #46 onto current `main`, preserving newer taxonomy/source-outage knowledge and adding provider credential routing facts, including diagnostic `auth show`.
**Pages updated:** wiki/architecture.md, wiki/api.md, wiki/commands.md, wiki/data-model.md, wiki/dependencies.md, wiki/active-areas.md, wiki/decisions.md, wiki/gaps.md, wiki/index.md, wiki/log.md
**Decision:** Provider API-key values stay out of repo/env-file docs and route through 1Password, the platform keychain, or env-only CI mode; `auth.toml` records routing metadata only. `auth show` is documented as a sensitive diagnostic command because it prints the resolved credential.
**Source:** `lib/xbookmark/keystore/{provider,auth_config,resolver,one_password,keychain,libsecret}.rb`, `lib/xbookmark/cli/auth.rb`, README Secrets section, and PR #46 rebase conflict resolution.
