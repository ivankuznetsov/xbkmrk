# frozen_string_literal: true

require "test_helper"
require "open3"
require "securerandom"

# End-to-end auth tests that spawn `bin/xbookmark` as a real subprocess.
#
# The host keychain CLI (`secret-tool` on Linux, `security` on macOS) and
# the 1Password CLI (`op`) are replaced with shim binaries on PATH that
# record their invocations into a transcript file.  This exercises the
# entire CLI plumbing -- argv parsing, Provider parsing, AuthConfig write,
# backend dispatch -- without touching the developer's real GNOME Keyring,
# Keychain Access, or 1Password vault.
#
# Provider names are uniquified per-run (xbookmark-test-<hex>) so a
# failing test that escapes its `ensure` cannot poison a developer's real
# keystore on the same machine.
describe "auth end-to-end via bin/xbookmark" do
  ROOT = File.expand_path("../..", __dir__)
  # `test_helper.rb#reset_test_env!` clears PATH from ENV, so we capture
  # the host PATH at file-load time.  Fallback to a sane default if even
  # that was wiped before this file was required.
  HOST_PATH = (ENV["PATH"] && !ENV["PATH"].empty? ? ENV["PATH"] : "/usr/local/bin:/usr/bin:/bin").freeze

  before do
    @tmpdir = Dir.mktmpdir("xbookmark-auth-e2e")
    @bin_dir = File.join(@tmpdir, "bin")
    @home = File.join(@tmpdir, "home")
    @transcript = File.join(@tmpdir, "transcript.log")
    FileUtils.mkdir_p(@bin_dir)
    FileUtils.mkdir_p(@home)
    @provider = "xbookmark-test-#{SecureRandom.hex(4)}"
  end

  after do
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def linux?
    RbConfig::CONFIG["host_os"] =~ /linux/i
  end

  def macos?
    RbConfig::CONFIG["host_os"] =~ /darwin/i
  end

  def write_shim(name, body)
    path = File.join(@bin_dir, name)
    File.write(path, "#!/usr/bin/env bash\nset -e\n#{body}\n")
    File.chmod(0o755, path)
  end

  def install_keychain_shim
    store_dir = File.join(@tmpdir, "kc-store")
    FileUtils.mkdir_p(store_dir)

    if linux?
      write_shim("secret-tool", <<~SH)
        cmd="$1"; shift
        printf "%s %s\\n" "$cmd" "$*" >> "#{@transcript}"
        account=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "account" ]; then account="$2"; fi
          shift
        done
        case "$cmd" in
          store)  cat > "#{store_dir}/$account" ;;
          lookup) if [ -f "#{store_dir}/$account" ]; then cat "#{store_dir}/$account"; else exit 1; fi ;;
          clear)  rm -f "#{store_dir}/$account" ;;
          search)
            for f in "#{store_dir}"/*; do
              [ -f "$f" ] || continue
              printf "attribute.account = %s\\n" "$(basename "$f")"
            done
            ;;
        esac
      SH
      "libsecret"
    elsif macos?
      write_shim("security", <<~SH)
        cmd="$1"; shift
        printf "%s %s\\n" "$cmd" "$*" >> "#{@transcript}"
        account=""
        value=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -a) account="$2"; shift ;;
            -w) value="$2"; shift ;;
          esac
          shift
        done
        case "$cmd" in
          add-generic-password)
            printf "%s" "$value" > "#{store_dir}/$account"
            ;;
          find-generic-password)
            if [ -f "#{store_dir}/$account" ]; then cat "#{store_dir}/$account"; printf "\\n"; else exit 1; fi
            ;;
          delete-generic-password)
            rm -f "#{store_dir}/$account"
            ;;
        esac
      SH
      "keychain"
    end
  end

  def run_xbookmark(*argv, stdin: nil, env: {})
    cmd_env = {
      "PATH" => "#{@bin_dir}:#{HOST_PATH}",
      "HOME" => @home,
      "XDG_CONFIG_HOME" => File.join(@home, ".config"),
      "CI" => nil,
      "XBOOKMARK_KEYS_FROM_ENV" => nil,
      # The resolver's keychain probe gates libsecret on a D-Bus session. The
      # `secret-tool` shim ignores D-Bus, but the gate only checks the env var
      # is present, so set it explicitly — a headless CI runner may not export
      # one, which would otherwise make `auth show` refuse the shim.
      "DBUS_SESSION_BUS_ADDRESS" => "unix:path=/run/user/1000/bus"
    }.merge(env)
    ruby = RbConfig.ruby
    Open3.capture3(cmd_env, ruby, "-I", File.join(ROOT, "lib"),
                   File.join(ROOT, "bin", "xbookmark"),
                   *argv, stdin_data: stdin || "")
  end

  it "auth login round-trips through the platform keychain shim" do
    # No conditional skip: the keychain round-trip is the primary acceptance
    # scenario, so on a host without a supported backend this test must *fail*
    # (install_keychain_shim returns nil and the assertions below break) rather
    # than silently no-cover it. CI runs on Linux/macOS where a shim installs.
    backend_name = install_keychain_shim

    out, err, status = run_xbookmark("auth", "login", @provider, stdin: "sk-secret-value\n")
    assert status.success?, "CLI exited non-zero: #{err}"
    assert_match(/Stored #{Regexp.escape(@provider)} in #{backend_name}\./, out)

    cfg_path = File.join(@home, ".config", "xbookmark", "auth.toml")
    assert File.file?(cfg_path), "expected auth.toml at #{cfg_path}"
    assert_equal 0o600, File.stat(cfg_path).mode & 0o777
    contents = File.read(cfg_path)
    assert_match(/\[#{Regexp.escape(@provider)}\]/, contents)
    assert_match(/backend = "keychain"/, contents)

    out2, err2, status2 = run_xbookmark("auth", "show", @provider)
    assert status2.success?, "auth show failed: #{err2}"
    assert_equal "sk-secret-value", out2.strip
  end

  it "auth bind + auth show resolves through the op shim" do
    write_shim("op", <<~SH)
      cmd="$1"; shift
      printf "%s %s\\n" "$cmd" "$*" >> "#{@transcript}"
      if [ "$cmd" = "read" ]; then
        if [ "$1" = "--no-newline" ]; then shift; fi
        printf "sk-op-value"
      fi
    SH

    out, err, status = run_xbookmark("auth", "bind", @provider, "op://CI Test/xbookmark-fixture/value")
    assert status.success?, "auth bind failed: #{err}"
    assert_match(/Bound/, out)

    out2, err2, status2 = run_xbookmark("auth", "show", @provider)
    assert status2.success?, "auth show failed: #{err2}"
    assert_equal "sk-op-value", out2.strip

    assert_match(%r{read .*op://CI Test/xbookmark-fixture/value}, File.read(@transcript))
  end

  it "CI=true short-circuits to env without invoking any backend shim" do
    %w[secret-tool op security].each do |tool|
      write_shim(tool, <<~SH)
        echo "FAIL: #{tool} was invoked under CI=true" >&2
        printf "%s %s\\n" "$0" "$*" >> "#{@transcript}"
        exit 99
      SH
    end

    env_var = "XBOOKMARK_#{@provider.upcase.tr("^A-Z0-9", "_")}_KEY"
    out, err, status = run_xbookmark(
      "auth", "show", @provider,
      env: { "CI" => "true", env_var => "sk-from-ci-env" }
    )
    assert status.success?, "auth show failed: #{err}"
    assert_equal "sk-from-ci-env", out.strip
    refute File.exist?(@transcript),
      "expected no shim to be invoked under CI=true, but transcript exists"
  end

  it "auth show raises a friendly error when nothing is configured" do
    _out, err, status = run_xbookmark("auth", "show", @provider)
    refute status.success?
    assert_match(/auth login #{Regexp.escape(@provider)}/, err)
    assert_match(%r{auth bind #{Regexp.escape(@provider)} op://}, err)
  end
end
