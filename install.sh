#!/bin/sh
# xbookmark installer — pure POSIX sh, no bashisms.
#
# Usage:
#   curl -fsSL https://github.com/ivankuznetsov/xbkmrk/raw/main/install.sh | sh
#
# Or with overrides:
#   XBOOKMARK_TAG=v1.2.3 XBOOKMARK_REPO=ivankuznetsov/xbkmrk sh install.sh
#
# Strategy:
#   1. Detect arch (x86_64-linux or arm64-darwin); bail otherwise.
#   2. Download the matching Tebako binary from the release.
#   3. Verify the SHA256 against the published SHA256SUMS.
#   4. Place at $XBOOKMARK_PREFIX/bin/xbookmark (default ~/.local/bin).
#   5. Ensure prefix/bin is on PATH (offer to append to the user's rc).
#
# Replaces an existing binary so re-running the script performs an upgrade.

set -eu

XBOOKMARK_REPO="${XBOOKMARK_REPO:-ivankuznetsov/xbkmrk}"
XBOOKMARK_TAG="${XBOOKMARK_TAG:-latest}"
XBOOKMARK_PREFIX="${XBOOKMARK_PREFIX:-$HOME/.local}"
XBOOKMARK_RELEASE_BASE="${XBOOKMARK_RELEASE_BASE:-https://github.com/${XBOOKMARK_REPO}/releases}"
# Binary is the supported default until the RubyGem is published. Set
# XBOOKMARK_INSTALL_METHOD=gem explicitly to opt into RubyGems.
XBOOKMARK_INSTALL_METHOD="${XBOOKMARK_INSTALL_METHOD:-binary}"

say()  { printf '%s\n'   "[xbookmark] $*"; }
warn() { printf '%s\n'   "[xbookmark] $*" >&2; }
die()  { warn "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

detect_arch() {
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  case "${uname_s}-${uname_m}" in
    Linux-x86_64)   echo "x86_64-linux" ;;
    Darwin-arm64)   echo "arm64-darwin" ;;
    *)              die "xbookmark v1 only supports x86_64-linux and arm64-darwin (got ${uname_s}-${uname_m})." ;;
  esac
}

# Returns 0 if a compatible system Ruby (>= 3.1) is on PATH.
have_compatible_ruby() {
  command -v ruby >/dev/null 2>&1 || return 1
  command -v gem  >/dev/null 2>&1 || return 1
  ver="$(ruby -e 'print RUBY_VERSION')" || return 1
  major="$(echo "$ver" | cut -d. -f1)"
  minor="$(echo "$ver" | cut -d. -f2)"
  if [ "$major" -gt 3 ]; then return 0; fi
  if [ "$major" -eq 3 ] && [ "$minor" -ge 1 ]; then return 0; fi
  return 1
}

download() {
  url="$1"; out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$out" "$url" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url" || return 1
  else
    die "need curl or wget"
  fi
}

resolve_release_path() {
  # Tag form: download/v1.2.3/<file> ; latest form: latest/download/<file>
  if [ "$XBOOKMARK_TAG" = "latest" ]; then
    echo "${XBOOKMARK_RELEASE_BASE}/latest/download"
  else
    echo "${XBOOKMARK_RELEASE_BASE}/download/${XBOOKMARK_TAG}"
  fi
}

verify_sha256() {
  file="$1"; expected="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  else
    die "no sha256 tool available; refusing to install an unverified binary."
  fi
  if [ "$actual" != "$expected" ]; then
    die "checksum mismatch for $file: expected $expected, got $actual"
  fi
  say "checksum ok: $actual"
}

install_via_gem() {
  say "found compatible Ruby; installing xbookmark from rubygems."
  if [ "$XBOOKMARK_TAG" = "latest" ]; then
    gem install --user-install xbookmark
  else
    version_no_v="${XBOOKMARK_TAG#v}"
    gem install --user-install --version "$version_no_v" xbookmark
  fi
}

install_tebako_binary() {
  arch="$1"
  base="$(resolve_release_path)"
  binary_name="xbookmark-${arch}"
  binary_url="${base}/${binary_name}"
  sums_url="${base}/SHA256SUMS"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  say "downloading $binary_url"
  download "$binary_url" "$tmpdir/$binary_name"

  download "$sums_url" "$tmpdir/SHA256SUMS" || die "could not fetch SHA256SUMS; refusing to install."
  expected="$(awk -v name="$binary_name" '$2 == name || $2 == "*" name {print $1}' "$tmpdir/SHA256SUMS")"
  [ -n "$expected" ] || die "SHA256SUMS did not contain a row for $binary_name."
  verify_sha256 "$tmpdir/$binary_name" "$expected"

  install_dir="${XBOOKMARK_PREFIX}/bin"
  target="${install_dir}/xbookmark"

  if [ -e "$target" ]; then
    say "replacing existing $target."
  fi

  mkdir -p "$install_dir"
  mv "$tmpdir/$binary_name" "$target"
  chmod +x "$target"
  say "installed to $target"

  if [ "$arch" = "arm64-darwin" ]; then
    say "macOS: if Gatekeeper quarantines the binary, run:"
    say "  xattr -d com.apple.quarantine $target"
  fi
}

ensure_path() {
  install_dir="${XBOOKMARK_PREFIX}/bin"
  case ":${PATH}:" in
    *":${install_dir}:"*) return 0 ;;
  esac

  rc=""
  case "${SHELL:-}" in
    */zsh)  rc="$HOME/.zshrc" ;;
    */bash) rc="$HOME/.bashrc" ;;
    */fish) rc="$HOME/.config/fish/config.fish" ;;
  esac

  say "${install_dir} is not on PATH."
  if [ -z "$rc" ] || [ ! -f "$rc" ]; then
    say "  append the following to your shell rc manually:"
    say "    export PATH=\"${install_dir}:\$PATH\""
    return 0
  fi

  printf '[xbookmark] append `export PATH="%s:$PATH"` to %s? [y/N] ' "$install_dir" "$rc"
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES)
      printf '\n# Added by xbookmark install.sh\nexport PATH="%s:$PATH"\n' "$install_dir" >> "$rc"
      say "appended to $rc"
      ;;
    *)
      say "  skipped; add to PATH manually."
      ;;
  esac
}

main() {
  arch="$(detect_arch)"
  say "detected platform: $arch"

  case "$XBOOKMARK_INSTALL_METHOD" in
    binary)
      install_tebako_binary "$arch"
      ensure_path
      ;;
    gem)
      have_compatible_ruby || die "XBOOKMARK_INSTALL_METHOD=gem requires Ruby >= 3.1 and gem on PATH."
      install_via_gem
      ;;
    *)
      die "unsupported XBOOKMARK_INSTALL_METHOD=$XBOOKMARK_INSTALL_METHOD (expected binary or gem)."
      ;;
  esac

  say "install complete.  Run \`xbookmark\` to launch the setup wizard."
}

main "$@"
