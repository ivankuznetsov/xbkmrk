---
title: xbookmark Wiki
type: index
source: wiki/**/*.md
created: 2026-05-14
updated: 2026-08-16
tags: [index, wiki]
---

**TLDR**: Catalog of the LLM-maintained wiki for `xbookmark`.

Page count: 11
Updated: 2026-08-16

## Core Pages

- [[architecture]] - Birdclaw/X inputs, OpenRouter routing, QMD registration, scheduling, and coverage gate.
- [[api]] - Birdclaw SQLite, OpenRouter, OAuth callback, X API, and QMD surfaces.
- [[commands]] - CLI command surface, fresh setup contract, first-run setup wizard, doctor fixes, taxonomy repair, install, and uninstall behavior.
- [[data-model]] - SQLite state schema, bookmark wiki layout, statuses, modes, and transactional behavior.
- [[dependencies]] - Ruby gems, OpenRouter, Birdclaw, QMD/Whisper tools, schedulers, and contributor checks.
- [[decisions]] - Repository, update-only import, model routing, setup, and coverage decisions grounded in code/history.
- [[active-areas]] - OpenRouter/Birdclaw cutover, local setup, pagination, and verification state.
- [[live-production-learnings]] - Production backfill lessons, source limits, media/transcript fixes, Codex/QMD behavior, and reusable verification commands.

## Maintenance Pages

- [[gaps]] - Known uncertainty and verification gaps.
- [[index]] - This catalog.
- [[log]] - Append-only wiki changelog.

## Maintenance

- Managed config: `.llm-wiki/config.json`
- Headless refresh: `.llm-wiki/refresh-wiki.sh`
- Post-commit refresh: `.llm-wiki/post-commit-refresh.sh`
- Main cross-project wiki searched: `/home/asterio/wikis/master/wiki`
