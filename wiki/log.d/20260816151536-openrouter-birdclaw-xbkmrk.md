## 2026-08-16 — OpenRouter, Birdclaw updates, and xbkmrk

- Replaced runtime local-Codex enrichment with an OpenRouter client using `~deepseek/deepseek-v4-flash-latest` for text-only prompts and `qwen/qwen3.8-27b` when images are present.
- Added read-only, idempotent `import-birdclaw` support so an existing extracted bookmark archive can update the wiki without a historical X backfill.
- Hydrated OpenRouter credentials for offline commands, shared the taxonomy writer lock, and retained text-only fallback when image enrichment fails.
- Hardened the archive boundary with bounded SQLite pages, direct X-CDN media URLs, retry-state preservation, post-skip limits, graceful lock contention, partial-import state, and QMD refresh.
- Made setup OpenRouter-first and Birdclaw-only by default; X credentials and the daily direct-X scheduler are optional.
- Updated current setup, packaging, and project-wiki documentation for the repository name `xbkmrk`; the installed executable and Ruby namespace remain `xbookmark` for compatibility.
