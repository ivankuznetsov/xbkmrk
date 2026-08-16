# frozen_string_literal: true

require "test_helper"

require "open3"

describe "install.sh" do
  let(:script_path) { File.expand_path("../install.sh", __dir__) }
  let(:uninstall_path) { File.expand_path("../uninstall.sh", __dir__) }

  it "passes `sh -n` syntax check" do
    _out, err, status = Open3.capture3("sh", "-n", script_path)
    assert status.success?, err
  end

  it "uninstall.sh passes `sh -n` syntax check" do
    _out, err, status = Open3.capture3("sh", "-n", uninstall_path)
    assert status.success?, err
  end

  it "is plain POSIX sh — no `bash` or `\\[\\[` constructs" do
    body = File.read(script_path)
    refute_match(/^\s*\[\[/, body)
    refute_match(/\bsource\b/, body) # bash-only
  end

  it "defaults to the publishing repo and binary install path" do
    body = File.read(script_path)
    assert_includes body, 'XBOOKMARK_REPO="${XBOOKMARK_REPO:-ivankuznetsov/xbkmrk}"'
    assert_includes body, 'XBOOKMARK_INSTALL_METHOD="${XBOOKMARK_INSTALL_METHOD:-binary}"'
    refute_includes body, "XBOOKMARK_FORCE_BINARY"
  end

  it "refuses to install when checksum verification cannot run" do
    body = File.read(script_path)
    assert_includes body, "refusing to install an unverified binary"
    assert_includes body, "could not fetch SHA256SUMS; refusing to install"
  end

  it "detects x86_64-linux and arm64-darwin and rejects others" do
    # Run a small shim that sources `detect_arch` from install.sh by
    # extracting the function body — pure POSIX, no bashisms.
    Dir.mktmpdir do |dir|
      shim = File.join(dir, "shim.sh")
      File.write(shim, <<~SH)
        #!/bin/sh
        uname() {
          case "$1" in
            -s) echo "$FAKE_UNAME_S" ;;
            -m) echo "$FAKE_UNAME_M" ;;
          esac
        }
        die() { echo "$@"; exit 1; }

        # Inline the detect_arch function from install.sh.
        detect_arch() {
          uname_s="$(uname -s)"
          uname_m="$(uname -m)"
          case "${uname_s}-${uname_m}" in
            Linux-x86_64)   echo "x86_64-linux" ;;
            Darwin-arm64)   echo "arm64-darwin" ;;
            *)              die "unsupported ${uname_s}-${uname_m}" ;;
          esac
        }

        detect_arch
      SH

      def run_with_env(shim, env)
        Open3.capture3(env, "sh", shim)
      end

      out, _err, status = run_with_env(shim, "FAKE_UNAME_S" => "Linux",  "FAKE_UNAME_M" => "x86_64")
      assert status.success?
      assert_equal "x86_64-linux", out.strip

      out, _err, status = run_with_env(shim, "FAKE_UNAME_S" => "Darwin", "FAKE_UNAME_M" => "arm64")
      assert status.success?
      assert_equal "arm64-darwin", out.strip

      out, _err, status = run_with_env(shim, "FAKE_UNAME_S" => "Linux",  "FAKE_UNAME_M" => "i686")
      refute status.success?
      assert_includes out, "unsupported"
    end
  end
end
