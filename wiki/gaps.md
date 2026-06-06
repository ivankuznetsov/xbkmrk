# Wiki Gaps

| Area | Gap | Notes |
|------|-----|-------|
| Production backfill completeness | Production wiki still needs a backfill rerun with 50-item pages | Code and docs now standardize on 50-item bookmark pages. The remaining uncertainty is production data completeness after rerunning against the 4,745 IDs found by the read-only probe. |
| Codex service-tier cleanup | Needs live setup/install verification after commit | Current code removes stale invalid top-level `service_tier` values, preserves valid speed modes, and specs cover parser/setup/install/atomic-write paths, but this refresh did not run a real setup/install against a user's live Codex config. |
| Post-commit diff source | Review checkout HEAD did not identify the xbookmark commit directly | On 2026-06-15, local `HEAD` was a grafted plugin-logo commit while xbookmark files appeared as untracked against that HEAD. This refresh used `origin/main..origin/feat/wiki-graph-taxonomy` at `c83d53c` plus visible source files. Confirm future post-commit refresh checkouts preserve a normal xbookmark HEAD if refreshes must inspect `HEAD` directly. |
| Cross-project wiki | No xbookmark-specific master page found | `/home/asterio/wikis/master/wiki` exists, but 2026-05-25 searches found no `xbookmark`-specific page. `~/wikis/main/wiki`, `../wikis/master/wiki`, and `../wikis/main/wiki` did not exist. |
| Provider credential real-backend CI | Provider routing is covered with tests and CLI shims, but not live 1Password/libsecret/Keychain CI | Tests cover `auth login PROVIDER`, `auth bind`, `auth list`, `auth show`, `auth rm`, resolver priority, and shimmed backend plumbing. Real backend validation needs macOS runners, a seeded 1Password service account secret, and a Linux D-Bus/libsecret job. |
| Keychain not-found exit codes | The "non-zero + empty stderr ⇒ absent" heuristic in the keychain backends assumes, but has not verified against the real tools, which exit codes mean "item not found" | `keychain.rb`/`libsecret.rb` now treat a nil `exitstatus` (signal kill) as a hard error rather than "absent", and `Libsecret#delete` tolerates a non-zero-with-empty-stderr clear as "already gone" (mirroring `Keychain#delete`'s exit-44 handling). The precise `secret-tool`/`security` not-found exit codes were inferred from behaviour, not confirmed from a live run; a real-backend smoke test could pin them. |

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
