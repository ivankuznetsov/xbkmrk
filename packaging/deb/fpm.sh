#!/bin/sh
# Build a Debian/Ubuntu .deb of xbookmark from the Tebako Linux
# binary.  Called by the `build-deb` job in
# .github/workflows/release.yml.
#
# Usage:  packaging/deb/fpm.sh <version> <path-to-tebako-binary>
#
# The Tebako binary needs no Ruby on the host because it bundles the
# interpreter — the only declared dep is `ffmpeg`, matching the
# detect-and-offer policy.
set -eu

VERSION="$1"
BINARY="$2"

if [ -z "$VERSION" ] || [ -z "$BINARY" ]; then
  echo "usage: $0 <version> <path-to-tebako-binary>" >&2
  exit 2
fi

if [ ! -f "$BINARY" ]; then
  echo "error: binary not found at $BINARY" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

install -Dm755 "$BINARY" "$STAGE/usr/bin/xbookmark"

fpm \
  --input-type dir \
  --output-type deb \
  --name xbookmark \
  --version "$VERSION" \
  --architecture amd64 \
  --maintainer "Ivan Kuznetsov <ivan@ikuznetsov.com>" \
  --description "Sync X (Twitter) bookmarks into a local Obsidian-ready bookmark wiki." \
  --url "https://github.com/ivankuznetsov/xbkmrk" \
  --license "MIT" \
  --depends "ffmpeg" \
  --after-install "$(dirname "$0")/postinst" \
  --before-remove "$(dirname "$0")/prerm" \
  --chdir "$STAGE" \
  .
