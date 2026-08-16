# Wiki Gaps

| Area | Gap | Notes |
|------|-----|-------|
| Existing corpus location | Earlier generated bookmark repository was not discoverable during the 2026-08-16 setup | The update-only importer can seed from an existing Birdclaw SQLite archive, but it must not be described as restoring a separately generated historical wiki that has not been located. |
| Video transcription | Local Whisper executable is optional | Image and text enrichment work through OpenRouter; video rows remain retryable when no supported local Whisper backend is installed. |
| Post-commit diff source | Review checkout HEAD did not identify the xbookmark commit directly | On 2026-06-15, local `HEAD` was a grafted plugin-logo commit while xbookmark files appeared as untracked against that HEAD. This refresh used `origin/main..origin/feat/wiki-graph-taxonomy` at `c83d53c` plus visible source files. Confirm future post-commit refresh checkouts preserve a normal xbookmark HEAD if refreshes must inspect `HEAD` directly. |
| Cross-project wiki | No xbookmark-specific master page found | `/home/asterio/wikis/master/wiki` exists, but 2026-05-25 searches found no `xbookmark`-specific page. `~/wikis/main/wiki`, `../wikis/master/wiki`, and `../wikis/main/wiki` did not exist. |

## Resolved Bootstrap Validation

- 2026-05-14: Managed llm-wiki config, agent context, post-commit hook, and daily systemd timer were validated for `xbookmark`.
- 2026-05-14: `qmd update`, `qmd embed`, and collection-scoped `qmd search` passed for `xbookmark`. QMD tries GPU first and falls back to CPU on this host because Vulkan headers are missing.
- 2026-05-14: `qmd query` can still be slow under the sandboxed local-model path; use `qmd search` for maintenance checks and fall back to `rg` when semantic generation is too slow.
- 2026-05-22: README command/config docs were reconciled to the implemented CLI so new setups do not follow unsupported `schedule`, `--config`, `auth logout`, `enrich`, or extra backfill/find flags. `auth refresh` is now implemented and documented.
- 2026-05-22: README Ruby version and contributor checks were reconciled to the gemspec and then-current test suite.
- 2026-05-25: Test suite, CI, README, and dependency notes now use Minitest with fixture-backed data and the 100% coverage gate.
- 2026-05-22: Scheduler installation is now part of the default setup flow, and QMD registration handles the current `qmd collection add` command shape.
- 2026-05-22: Runtime source, specs, CI config, and project wiki are now on `main`; the older "runtime not on main" gap is resolved.
- 2026-05-22: `.env.example` no longer references a nonexistent `auth login --port` option; setup uses `X_REDIRECT_URI`.
- 2026-05-22: Linux scheduler setup now tries to enable systemd linger automatically so daily timers can run after logout.
- 2026-05-22: Live production backfill exposed a Codex JSONL event-shape drift; `item.completed` agent messages are now parsed.
- 2026-05-22: Media download no longer has a default 200 MB cap; large X videos are allowed to download.
- 2026-05-22: Live OAuth, bookmark API, production scheduler, QMD, media, transcript, enrichment, and duplicate checks were validated against the production install. Durable lessons are captured in [[live-production-learnings]].
- 2026-05-25: `bundle exec rake coverage` is now the local 100% line-coverage gate for `bin/` and `lib/`; last recorded pass was 299 examples at 100.00% (2297/2297).
- 2026-08-16: Runtime enrichment moved from local Codex to OpenRouter with DeepSeek text routing and Qwen image routing; Birdclaw import provides an update-only path with no X backfill.
