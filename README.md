# xbookmark

Own your X bookmarks as a local, Obsidian-ready bookmark wiki with LLM enrichment and Whisper transcription.

xbookmark imports bookmarks from an existing local Birdclaw archive or pulls them through the official paid X API v2, writes each one to a plain markdown file with YAML frontmatter, enriches text and images through OpenRouter, and transcribes linked audio or video locally with Whisper.

It is built for people who keep notes in Obsidian or any markdown-first system and are tired of X bookmarks being unsearchable and ephemeral. xbookmark writes to its own standalone bookmark wiki directory; point Obsidian at that folder when you want to browse it. Bookmark state and transcription stay local; enrichment sends selected bookmark context to OpenRouter.

<p align="center">
  <a href="https://github.com/ivankuznetsov/xbkmrk/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/ivankuznetsov/xbkmrk/ci.yml?branch=main&label=ci" alt="Build status"></a>
  <a href="https://github.com/ivankuznetsov/xbkmrk/releases/latest"><img src="https://img.shields.io/github/v/release/ivankuznetsov/xbkmrk?label=release" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License"></a>
  <img src="https://img.shields.io/badge/ruby-%E2%89%A5%203.1-red" alt="Ruby version">
</p>

<p align="center">
  <img src="docs/assets/demo.gif" alt="xbookmark backfill and find demo">
</p>

Clone, install dependencies, and copy the env template:

```bash
git clone https://github.com/ivankuznetsov/xbkmrk.git
cd xbkmrk
bundle install
cp .env.example .env
```

Stop here and edit `.env` to fill in `OPENROUTER_API_KEY` and `XBOOKMARK_WIKI_PATH`. If you already have a Birdclaw archive, import it directly without X credentials or a historical X backfill:

```bash
bin/xbookmark import-birdclaw --db ~/.birdclaw/birdclaw.sqlite
bin/xbookmark find 'rails'
```

To fetch bookmarks from X instead, also fill in `X_CLIENT_ID` and `X_USER_ID`, then run:

```bash
bin/xbookmark auth login
bin/xbookmark install
bin/xbookmark backfill --limit 100
bin/xbookmark find 'rails'
```

Example `find` output:

```
bookmarks/2026/05/12/dhh-rails-8-ships-1789012345678901234.md  "Rails 8.0 ships with..."  @dhh
concepts/rails.md                                                "Rails"                    concept
```

## Quick install with an AI agent

If you use Claude Code, Cursor, Codex, ChatGPT, or any other AI assistant, paste the prompt below and let it install and configure xbookmark for you. Agents with shell access run the steps; chat-only agents walk you through them.

```text
Install and configure xbookmark from https://github.com/ivankuznetsov/xbkmrk on this machine.

1. Read README.md from that repo and follow the Installation section that matches my operating system.
2. Copy .env.example to .env and configure my OpenRouter key, bookmark wiki path, and existing Birdclaw database path.
3. Run `bin/xbookmark import-birdclaw`; do not run an X backfill when an extracted archive is available.
4. Configure X OAuth and install the daily scheduler only if I ask for future direct X syncs.
5. Verify with `bin/xbookmark --version` and `bin/xbookmark doctor`, then report the output.

Stop and ask me before installing system packages with sudo, and before any step that would overwrite a file in my home directory.
```

If you prefer to run the steps yourself, jump to [Installation](#installation) and [Configuration](#configuration) below.

## Features

- One-shot backfill of your entire X bookmark history into a local bookmark wiki.
- Daily incremental ingest via a built-in scheduler (systemd on Linux, launchd on macOS).
- Obsidian-friendly markdown output with YAML frontmatter and stable file naming.
- Full-text search over the bookmark wiki via a local QMD index (a markdown full-text search engine).
- OpenRouter enrichment with `~deepseek/deepseek-v4-flash-latest` for text and `qwen/qwen3.8-27b` for image-bearing bookmarks.
- Local Whisper transcription of audio and video linked from a bookmark, with
  LLM-produced transcript summaries and readable dialogue-style formatting.
- Obsidian graph landing pages for authors, canonical concepts, concept hierarchy, real multi-bookmark threads, and explicit post lists on topic/concept pages.
- Official X API v2 only, via OAuth 2.0 with PKCE.
- MIT-licensed and runs entirely on your machine.

## Installation

xbookmark ships pre-built single-file binaries for `x86_64-linux` and
`arm64-darwin`.  Pick the channel that matches your host:

| Channel | One-liner |
|---------|-----------|
| Homebrew (macOS, arm64) | `brew install ivankuznetsov/tap/xbookmark` |
| AUR (Arch / Manjaro) | `yay -S xbookmark` |
| `.deb` (Debian / Ubuntu, x86_64) | `sudo apt install ./xbookmark_<ver>_amd64.deb` |
| Generic `curl \| sh` | `curl -fsSL https://github.com/ivankuznetsov/xbkmrk/raw/main/install.sh \| sh` |

After install, run `xbookmark` once — it auto-launches the interactive
setup wizard, which writes the required OpenRouter key to the host keystore
(libsecret on Linux, login Keychain on macOS). X credentials are optional;
the wizard enables the daily X sync timer only when both X identifiers are set.

### Upgrades

Upgrade via the same channel you installed from — `brew upgrade
xbookmark`, `yay -Syu xbookmark`, `apt upgrade xbookmark`, or re-run
`install.sh`.  There is no in-binary `xbookmark update`.

### Uninstall

```bash
xbookmark uninstall --purge      # remove scheduler unit, keystore entries, config dir
# then, depending on channel:
brew uninstall xbookmark         # macOS
sudo pacman -R xbookmark         # Arch
sudo apt remove xbookmark        # Debian/Ubuntu
sh <(curl -fsSL https://github.com/ivankuznetsov/xbkmrk/raw/main/uninstall.sh)  # curl|sh path
```

Running the package-manager removal before `xbookmark uninstall
--purge` is supported but leaves orphan keystore entries behind; the
order above keeps the box clean.

### Troubleshooting

- **`ruby not found`** — the Tebako binary bundles its own Ruby, so
  this should never appear after the binary install.  If you see it,
  re-run `install.sh` and confirm the binary is on PATH.
- **`secret-tool missing` (Linux)** — install
  `libsecret`/`libsecret-tools` for your distro; otherwise xbookmark
  falls back to a 0600 `.env` at `~/.config/xbookmark/.env`.  `xbookmark
  doctor` always prints the active backend on its `keystore:` line.
- **Scheduler did not enable** — re-run `xbookmark install`.  On
  Arch/Linux you may need `loginctl enable-linger $USER` to fire while
  logged out; macOS launchd needs no extra setup.
- **macOS Gatekeeper quarantines the binary** — run `xattr -d
  com.apple.quarantine $(which xbookmark)`.

### Optional runtime tools

xbookmark detects the following at runtime and prints copy-pasteable
install commands when they are missing.  None of them are required to
launch the wizard:

- `ffmpeg` — media extraction.
- `whisper.cpp` / `faster-whisper` — local transcription.
- `qmd` — vector search over the bookmark wiki.

Run `xbookmark doctor` to see which ones the binary can find, and
`xbookmark doctor --fix` to interactively install the missing ones via
the host package manager.

### Building from source

If you prefer a source build, clone the repo and `bundle install`
against Ruby 3.1 or newer.  Source builds skip Tebako entirely.

```bash
git clone https://github.com/ivankuznetsov/xbkmrk.git
cd xbkmrk
bundle install
bin/xbookmark --version
```

## Configuration

xbookmark reads configuration from dotenv files. Resolution order is:
`XBOOKMARK_ENV_FILE`, `$PWD/.env`, then `~/.config/xbookmark/.env`.
Scheduled jobs keep using the env file that was loaded during installation,
so they do not depend on the scheduler's working directory.

Copy the example and fill in the values:

```bash
cp .env.example .env
```

### Configuration file

`.env.example` is the canonical key list. Keep real credentials only in
`.env` or another gitignored config file; do not edit `.env.example` with
secrets.

### Set up X API access

1. Sign in at the [X developer portal](https://developer.x.com) and create a project, then create an app inside it.
2. Enable OAuth 2.0 on the app. Set the callback URL to the value in `X_REDIRECT_URI`; the template default is `http://127.0.0.1:8765/callback`. If that port is permanently unavailable, change `X_REDIRECT_URI` and register the exact new callback URL in X.
3. Request the v1 scope set: `bookmark.read`, `users.read`, `tweet.read`, and `offline.access`. `offline.access` is intentional because xbookmark stores a refresh token for scheduled jobs.
4. Copy the Client ID into `X_CLIENT_ID` and your numeric X user ID into `X_USER_ID`. `X_CLIENT_SECRET` is only required if your app type is a confidential client that issues a secret; PKCE public-client apps leave it blank.
5. Run `bin/xbookmark auth login`. The CLI opens your browser, completes the PKCE handshake, and stores tokens back into the loaded env file with file mode `0600`.

### What this will cost

xbookmark uses the official paid X API. The README intentionally uses the
fallback path for now because pricing is checked at the merge gate, when the
CLI is ready to ship. Before merging to `main`, fetch the current
[X developer portal product tiers](https://developer.x.com/en/portal/products)
and add a dated estimate for Basic-tier dollars per 1000 bookmarks; until
then, use the published rate and quota on that page for your own estimate.

### OpenRouter authentication

Set `OPENROUTER_API_KEY` in a gitignored `.env`, or enter it when `xbookmark setup` prompts so the host keyring stores it. Text-only work uses `~deepseek/deepseek-v4-flash-latest`; any prompt with downloaded images uses `qwen/qwen3.8-27b`. Both model IDs are configurable through `.env`. No local Codex process or OpenAI credential is required.

### Whisper backend

Set `WHISPER_BACKEND` to either `whisper.cpp` (default, fast on CPU, one-time C++ build) or `faster-whisper` (Python, GPU-friendly) and ensure the matching backend is on your `PATH` — see [Prerequisites](#prerequisites). `WHISPER_MODEL` defaults to `base.en`; v1 accepts `tiny.en`, `base.en`, `small.en`, `medium.en`, `tiny`, `base`, `small`, `medium`, and `large-v3`. For `whisper.cpp`, model aliases resolve to `ggml-<model>.bin` in `WHISPER_MODEL_DIR`, the source checkout's `models/` directory next to `whisper-cli`, or `./models`. `WHISPER_THREADS` optionally overrides the whisper.cpp CPU thread count; when it is blank, xbookmark uses up to 8 local CPU threads.

### Aux page summaries

Every enriched bookmark links to author and canonical concept landing pages so Obsidian's graph works during large backfills. Concept pages include a `## Posts` section with direct links to matching source notes, so browsing does not depend on Obsidian's backlinks panel. Taxonomy rebuilds migrate legacy `topics/` and `entities/` links into `concepts/`, prune the old landing pages, and suppress author-handle concepts that would duplicate the author page. Real thread pages are written only when local state shows a multi-bookmark conversation. Author landing pages are lightweight placeholders by default to keep the main bookmark pipeline fast. Set `XBOOKMARK_AUX_SUMMARIES=true` to ask the configured OpenRouter text model for separate author summaries during sync.

### Bookmark wiki path

Set `XBOOKMARK_WIKI_PATH` to the directory where xbookmark should create its standalone bookmark wiki from X data. This runtime output is separate from this repository's `wiki/` project LLM wiki. Use an xbookmark-owned folder you will later open from Obsidian, not an existing general-purpose Obsidian vault. On first run xbookmark creates the directory if it is missing, including any missing parent directories, with mode `0755` so normal sync and group-readable wiki workflows keep working. Credentials and OAuth tokens stay in the active keystore when available, falling back to a `0600` env file under `~/.config/xbookmark`. If the bookmark wiki path already exists but is not a directory, xbookmark exits non-zero without modifying it. See [Obsidian integration](#obsidian-integration) for how to open it in Obsidian.

For compatibility with earlier local branches, `XBOOKMARK_VAULT`,
`OBSIDIAN_VAULT_PATH`, and the `--vault` CLI option are still accepted as
aliases. Prefer `XBOOKMARK_WIKI_PATH` and `--wiki` in new setups.

## Usage

### auth

Manage X API credentials.

```bash
bin/xbookmark auth login   # browser PKCE flow, stores tokens locally
bin/xbookmark auth status  # show whether the access token is present and still current
bin/xbookmark auth refresh # test and rotate the saved refresh token now
```

Example output:

```
Logged in. Token expires at: 1789012345 (2026-09-10T03:52:25Z)
```

`auth login` binds the host and port from `X_REDIRECT_URI`. Register that exact
callback URL in the X developer portal before signing in.
If `auth status` reports an expired access token, run `auth refresh`. If X rejects
the saved refresh token, re-run `auth login` to issue a new token pair.

### backfill

Pull historical bookmarks into the bookmark wiki.

```bash
bin/xbookmark backfill [--limit N]
```

Example:

```bash
bin/xbookmark backfill --limit 100
```

Example output:

```
processed=100 written=100 skipped=0 failed=0 permanent_errors=0
```

Without `--limit`, `backfill` paginates through all bookmarks currently exposed
by the X API. With `--limit`, it stops after that many new bookmarks, which is
useful for testing a new setup. xbookmark requests 50 bookmarks per API page and
follows `meta.next_token` until X stops returning one. The X endpoint accepts
larger page sizes up to 100, but live production testing showed that requesting
100 can omit pagination even when thousands of older bookmarks exist.

Backfill is idempotent. Rerunning it skips bookmarks already marked `done`, and
bookmark/media paths are deterministic with readable bookmark filenames that
retain the raw tweet ID suffix.

### import-birdclaw

Update the wiki from bookmarks already extracted into a local Birdclaw archive:

```bash
bin/xbookmark import-birdclaw [--db ~/.birdclaw/birdclaw.sqlite] [--limit N]
```

This command never constructs an X API client and never performs a historical X collection.
It reads Birdclaw's SQLite database in read-only mode, skips IDs
already marked `done`, and processes only new or previously failed local rows.
Rerun the same command whenever Birdclaw has collected more bookmarks.

### find

Full-text search across the bookmark wiki.

```bash
bin/xbookmark find '<query>' [--limit N]
```

Example:

```bash
bin/xbookmark find 'rails'
```

Example output:

```
1. [0.92] bookmarks/2026/05/12/dhh-rails-8-ships-1789012345678901234.md
   Rails 8.0 ships with Solid Cache...
2. [0.87] concepts/rails.md
   Rails
```

`find` searches the entire bookmark wiki through the QMD `bookmarks`
collection, so matches can include source notes, author pages, and concept
pages in a single result set.

### taxonomy

Audit or repair the generated wiki graph without fetching anything from X.

```bash
bin/xbookmark taxonomy audit
bin/xbookmark taxonomy rebuild          # dry-run; writes no files
bin/xbookmark taxonomy rebuild --apply  # snapshot + manifest + repair
```

`taxonomy audit` prints `clean` or `proposed_changes` (rebuild reports add
`applied` and `partial_failure`). Dry-run rebuilds exit non-zero when changes
are available; apply mode writes a pre-apply snapshot and manifest under
`$XBOOKMARK_WIKI_PATH/.xbookmark/`, renames numeric source notes to readable
filenames with the tweet ID suffix, rewrites links to legacy numeric thread
pages before pruning them (the legacy singleton-thread shape), writes a
graph-health report, materializes concept pages from local state, and reindexes
QMD. The snapshot is kept for manual recovery and audit evidence; rebuilds are
forward-only, so a mid-apply failure leaves completed repairs in place and
reports `partial_failure`. Scheduled sync runs the same local maintenance path
when X is unavailable, so cleanup and enrichment maintenance do not depend on
live X access.

### install

Install or remove the daily ingest job.

```bash
bin/xbookmark install [--time HH:MM] [--dry-run]
bin/xbookmark install --uninstall
```

The scheduler is always daily. `--time` defaults to `06:00` local time.
`--dry-run` prints the scheduler artifact without writing it. On Linux,
xbookmark installs a systemd user timer and enables systemd linger for the
current user when possible, so the timer can fire after logout. On macOS, it
installs a launchd agent.

Example output on Linux with systemd:

```
[xbookmark] systemd timer installed. Logs: ~/.local/state/xbookmark/sync.log
[xbookmark] systemd linger enabled; timer can run while logged out.
```

Example output on macOS:

```
[xbookmark] launchd agent installed at ~/Library/LaunchAgents/io.xbookmark.sync.plist
```

See [Scheduling](#scheduling) for the per-OS artifact and log locations.

### Help

Every subcommand accepts `--help`. The top-level `bin/xbookmark --help` lists all subcommands and global flags.

## How it works

xbookmark reads an existing Birdclaw archive or fetches updates through X API v2, writes each bookmark as a readable markdown source note with YAML frontmatter, then runs OpenRouter enrichment: DeepSeek V4 Flash Latest for text-only prompts and Qwen 3.8 27B for prompts containing images. Linked audio or video can be transcribed locally with Whisper. The taxonomy normalizer turns concept candidates into canonical pages with broader links and nested tag facets. A QMD index over the bookmark wiki gives you fast full-text search through `bin/xbookmark find`.

```text
Birdclaw SQLite or X API -> Ingest -> OpenRouter -> Bookmark wiki -> QMD index
                              |           ^                         |
                              +-> Whisper                          v
                                  media                    bin/xbookmark find
```

## Obsidian integration

To open the bookmark wiki in Obsidian, choose "Open folder as vault" from the Obsidian launcher and pick the directory you configured as `XBOOKMARK_WIKI_PATH`. Bookmarks land under `bookmarks/YYYY/MM/DD/<readable-slug>-<tweet_id>.md`, partitioned by `bookmarked_at`. The readable slug comes from a concise `title` the enrichment produces.

Bookmark frontmatter is written as queryable Obsidian Properties: a `title`, typed `created_at`/`bookmarked_at` dates, a `tags` keyword list, and `concepts` slugs — so you can filter and sort with Obsidian Bases or Dataview. `bin/xbookmark taxonomy rebuild --apply` migrates older notes to this shape in place, offline (no re-fetch, no re-enrichment).

The graph view picks up wikilinks between source notes, authors, concepts, and real threads. Concepts live under `concepts/`; broad concepts such as `venezuela` can link to child concepts such as `venezuela-oil` and `venezuela-politics`. Concept pages include `## Posts`, inheriting posts from child concepts, so opening `venezuela` shows source notes tagged with narrower concepts like `venezuela-politics`. Legacy `topics/` and `entities/` links are migrated into canonical concepts and the old landing pages are pruned during taxonomy rebuilds. Nested tags such as `area/venezuela` and `facet/politics` are filter facets, not the primary hierarchy.

Before inspecting a large existing wiki, run `bin/xbookmark taxonomy audit`.
If it reports `proposed_changes`, run `bin/xbookmark taxonomy rebuild --apply`
and inspect the graph-health report path printed by the command. In Obsidian,
start from `concepts/index.md`; for graph browsing, hide attachments and
optionally filter out `path:bookmarks/` when you want to inspect concept
topology without every source note dominating the canvas.

A typical bookmark file looks like this:

```markdown
---
tweet_id: "1789012345678901234"
author: dhh
created_at: "2026-05-12T08:14:00Z"
bookmarked_at: "2026-05-12T19:22:10Z"
tags:
  - rails
  - framework
concepts:
  - rails
  - rails-8
facets:
  - concept/rails
  - concept/rails-8
---

# @dhh: Rails 8.0 ships

Rails 8.0 ships today. Solid Cache, Solid Queue, Solid Cable are all defaults now.

## Concepts

- [[concepts/rails|Rails]]
- [[concepts/rails-8|Rails 8]]
```

## Scheduling

xbookmark installs its own daily ingest job using the native scheduler on each OS, so you do not need a separate scheduler config file.

```bash
bin/xbookmark install
bin/xbookmark install --time 09:00
bin/xbookmark install --dry-run
bin/xbookmark install --uninstall
```

The installer writes a command that invokes `bin/xbookmark sync
--from-scheduler`. Scheduled sync skips if the previous completed run is still
inside the minimum interval window. The loaded env file is preserved through
the scheduler artifact, either as a systemd `EnvironmentFile` or launchd
`XBOOKMARK_ENV_FILE` environment variable.

Scheduler selection is platform-based: macOS uses launchd, and Linux uses a
systemd user timer. Linux installs also try to enable systemd linger for the
current user; if your system refuses that step, xbookmark prints the
`loginctl enable-linger <user>` command to run manually.

The artifact written depends on your OS:

| OS | Artifact | Logs |
| --- | --- | --- |
| macOS | `~/Library/LaunchAgents/io.xbookmark.sync.plist` | `~/Library/Logs/xbookmark/sync.log` |
| Linux | `~/.config/systemd/user/xbookmark-sync.{service,timer}` | `~/.local/state/xbookmark/sync.log` |

If X is unreachable or the saved OAuth refresh token is rejected during a scheduled run, the job still exits successfully when no local bookmark processing failed. It logs `source blocked`, continues local taxonomy cleanup, QMD maintenance, and cached retry/enrichment work, and does not stamp the run as completed so the next timer can fetch new bookmarks after auth is repaired. A manual `bin/xbookmark sync` still exits non-zero on source errors. Re-run `bin/xbookmark auth login` to re-issue a rejected refresh token.

`bin/xbookmark install --uninstall` removes whichever artifact was created on this machine. Log files are preserved.

## FAQ

**How much will this cost?**
xbookmark uses the official paid X API only for direct X fetches; importing an existing Birdclaw archive avoids those fetches. OpenRouter bills model usage, while local Whisper transcription has no per-call provider fee.

**Whisper transcription is slow.**
The default is `WHISPER_MODEL=base.en`. xbookmark extracts downloaded video audio with `ffmpeg`, runs whisper.cpp with up to 8 CPU threads by default, and extends the subprocess timeout for long videos based on their duration. For faster runs, set `WHISPER_THREADS` to a higher value your machine can spare, switch to a smaller accepted model such as `tiny.en`, or switch backend to `faster-whisper` and run it on a GPU. The [whisper.cpp build docs](https://github.com/ggml-org/whisper.cpp#quick-start) cover Metal, CUDA, and OpenBLAS acceleration.

**OpenRouter authentication failed.**
Refresh `OPENROUTER_API_KEY` in the active keyring or gitignored env file, then rerun `bin/xbookmark import-birdclaw` or `bin/xbookmark sync`; bookmarks left without `enriched_at` are retried.

**X API rate-limited me.**
`backfill` respects the published `bookmark.read` rate limits but a long backfill can still hit the current rate-limit window. Lower `--limit` and re-run later, or schedule a daily ingest instead. The X API [rate-limit reference](https://docs.x.com/x-api/fundamentals/rate-limits) on `docs.x.com` lists the current numbers.

**Can I fetch more than 100 bookmarks at once?**
Not in one API request. X rejects bookmark requests with `max_results` above
100, and live testing showed `max_results=100` can fail to return older pages.
To fetch hundreds or thousands of bookmarks, keep the page size below that and
follow `meta.next_token`; xbookmark uses 50 per page and does this
automatically during `backfill`.

**Where are my markdown files?**
Under `$XBOOKMARK_WIKI_PATH/bookmarks/YYYY/MM/DD/<readable-slug>-<tweet_id>.md`. Concept pages live under `$XBOOKMARK_WIKI_PATH/concepts/`. The `bin/xbookmark find` output prints these paths so you can open them in your editor directly, or `cd "$(dirname ...)"` into the containing folder.

**Where are tokens stored?**
`auth login` writes `X_ACCESS_TOKEN`, `X_REFRESH_TOKEN`, and
`X_TOKEN_EXPIRES_AT` into the loaded env file, or into `$PWD/.env` when no env
file was loaded. The file is chmodded to `0600`.

## Roadmap

No commitments, no timeline — just the directions I expect to take next.

- Publish as a RubyGem so installation is `gem install xbookmark`.
- Ship an AUR package for Arch users.
- Ship a Homebrew tap for macOS users.
- Add Threads and Bluesky as adjacent bookmark providers.
- Encrypt the stored credentials file at rest.
- Expose a plugin API for custom enrichers (translation, sentiment, fact-check).

## Contributing

Dev setup is the same as a user install: `git clone`, `bundle install`, `cp .env.example .env`, and confirm with `bin/xbookmark --version`.

Tests run with `bundle exec rake test`. Routine contributor test runs stub external services and do not hit the X API. `bundle exec rake coverage` enforces 100% line coverage over `bin/` and `lib/`.

Pull requests should be small and focused — one logical change per PR — and pass the same checks as CI before pushing:

```bash
bundle exec rake test
bundle exec rake coverage
bundle exec rubocop --parallel
bundle exec brakeman --force --no-pager --quiet --ignore-config config/brakeman.ignore
bundle exec bundler-audit check --update
```

Link any related issue in the PR description.

## Credits

xbookmark uses [OpenRouter](https://openrouter.ai/) with DeepSeek and Qwen models for enrichment, [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and [faster-whisper](https://github.com/SYSTRAN/faster-whisper) for local transcription, QMD for markdown search, [Obsidian](https://obsidian.md) for browsing the bookmark wiki, Birdclaw for local extracted bookmark input, and the official X API for optional direct syncs.

## Security

Please report security issues privately to <ivan@ikuznetsov.com> rather than opening a public GitHub issue. I aim to acknowledge reports within 3 business days and coordinate a fix and disclosure timeline from there.

## License

MIT, Copyright (c) 2026 Ivan Kuznetsov. See [LICENSE](LICENSE) for the full text.
