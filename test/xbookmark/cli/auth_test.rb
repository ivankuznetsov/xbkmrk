# frozen_string_literal: true

require "test_helper"
require "xbookmark/cli/auth"
require "xbookmark/keystore/auth_config"
require "xbookmark/keystore/one_password"
require "xbookmark/keystore/keychain"
require "xbookmark/keystore/libsecret"

describe Xbookmark::CLI::Auth do
  def run_cli(*argv, stdin: nil)
    captured_stdout = StringIO.new
    captured_stderr = StringIO.new
    orig_stdout, orig_stderr, orig_stdin = $stdout, $stderr, $stdin
    $stdout = captured_stdout
    $stderr = captured_stderr
    if stdin
      $stdin = stdin
    end
    Xbookmark::CLI::Auth.start(argv)
    [captured_stdout.string, captured_stderr.string]
  ensure
    $stdout = orig_stdout
    $stderr = orig_stderr
    $stdin = orig_stdin
  end

  # Run the CLI when it is expected to `exit 1`, returning the stderr it wrote.
  # `run_cli` discards its captured streams on SystemExit, so commands that warn
  # then exit need their stderr captured directly (as the `show` tests do).
  def run_cli_expect_exit(*argv, stdin: nil)
    captured_stderr = StringIO.new
    orig_stdout, orig_stderr, orig_stdin = $stdout, $stderr, $stdin
    $stdout = StringIO.new
    $stderr = captured_stderr
    $stdin = stdin if stdin
    assert_raises(SystemExit) { Xbookmark::CLI::Auth.start(argv) }
    captured_stderr.string
  ensure
    $stdout = orig_stdout
    $stderr = orig_stderr
    $stdin = orig_stdin
  end

  before do
    @tmpdir = Dir.mktmpdir("xbookmark-auth-cli")
    @auth_toml = File.join(@tmpdir, "auth.toml")
    Xbookmark::Paths.stubs(:default_config_dir).returns(@tmpdir)
    # The Linux libsecret backend selection now gates on a live D-Bus session
    # (mirroring the Resolver and Keystore probes). Present one explicitly so the
    # login/rm tests verify backend behaviour regardless of the host, instead of
    # depending on the runner's ENV (a headless CI box may lack D-Bus).
    @orig_dbus = ENV["DBUS_SESSION_BUS_ADDRESS"]
    ENV["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/run/user/1000/bus"
  end

  after do
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
    @orig_dbus.nil? ? ENV.delete("DBUS_SESSION_BUS_ADDRESS") : (ENV["DBUS_SESSION_BUS_ADDRESS"] = @orig_dbus)
  end

  describe "login (no arg)" do
    it "still invokes Xbookmark::X::Auth#login" do
      require "xbookmark/config"
      require "xbookmark/x/auth"
      fake_config = Object.new
      Xbookmark::Config.stubs(:load).returns(fake_config)
      auth_result = Struct.new(:env_file).new("/tmp/x.env")
      auth_double = mock("x-auth")
      auth_double.expects(:login).returns(auth_result)
      Xbookmark::X::Auth.expects(:new).with(fake_config).returns(auth_double)

      _out, err = run_cli("login")
      assert_match(/Logged in/, err)
    end
  end

  describe "login PROVIDER" do
    it "writes to platform backend and updates auth.toml" do
      stub_platform_linux
      keychain_double = mock("kc")
      keychain_double.expects(:set).with("openrouter", "sk-secret").returns(true)
      keychain_double.stubs(:name).returns("libsecret")
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(keychain_double)

      stdin = StringIO.new("sk-secret\n")
      def stdin.tty?; false; end
      out, _err = run_cli("login", "openrouter", stdin: stdin)
      assert_match(/Stored openrouter in libsecret\./, out)

      reloaded = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      assert_equal "keychain", reloaded.lookup("openrouter")[:backend]
    end

    it "exits non-zero when no platform keychain is available" do
      stub_platform_linux
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(false)

      assert_raises(SystemExit) do
        run_cli("login", "openrouter", stdin: StringIO.new("sk\n").tap { |io| def io.tty?; false; end })
      end
    end

    it "exits before prompting on headless Linux (secret-tool present, no D-Bus session)" do
      stub_platform_linux
      # secret-tool is on PATH but there is no D-Bus session, exactly the
      # headless case the Resolver guards against. Selection must reject
      # libsecret *before* the hidden prompt reads — and never touch stdin —
      # so the user is not asked to type a key that cannot be stored.
      ENV.delete("DBUS_SESSION_BUS_ADDRESS")
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.expects(:new).never

      stdin = mock("stdin")
      stdin.expects(:gets).never
      err = run_cli_expect_exit("login", "openrouter", stdin: stdin)
      assert_match(/No platform keychain available/, err)
    end

    it "rejects an empty value" do
      stub_platform_linux
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(mock("kc"))

      stdin = StringIO.new("\n")
      def stdin.tty?; false; end
      assert_raises(SystemExit) { run_cli("login", "openrouter", stdin: stdin) }
    end

    it "rejects a whitespace-only value without ever calling the backend" do
      stub_platform_linux
      keychain_double = mock("kc")
      # The store-time `.strip.empty?` guard must reject "   " before any write,
      # matching the Resolver's `non_empty?` (which also strips) so the two
      # emptiness checks agree and a pure-spaces secret is never persisted.
      keychain_double.expects(:set).never
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(keychain_double)

      stdin = StringIO.new("   \n")
      def stdin.tty?; false; end
      run_cli_expect_exit("login", "openrouter", stdin: stdin)
    end

    it "reports an EOF on stdin distinctly from an entered-but-empty line" do
      stub_platform_linux
      keychain_double = mock("kc")
      keychain_double.expects(:set).never
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(keychain_double)

      stdin = StringIO.new("")
      def stdin.tty?; false; end
      err = run_cli_expect_exit("login", "openrouter", stdin: stdin)
      assert_match(/EOF/, err)
    end

    it "exits 1 with a clean message when the backend store fails" do
      stub_platform_linux
      keychain_double = mock("kc")
      keychain_double.expects(:set).raises(Xbookmark::Error, "keyring is locked")
      keychain_double.stubs(:name).returns("libsecret")
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(keychain_double)

      stdin = StringIO.new("sk-secret\n")
      def stdin.tty?; false; end
      err = run_cli_expect_exit("login", "openrouter", stdin: stdin)
      assert_match(/Could not store openrouter key in libsecret/, err)
      assert_match(/keyring is locked/, err)
    end

    it "names the stored-but-unrouted state when the auth.toml write fails after the store" do
      stub_platform_linux
      keychain_double = mock("kc")
      keychain_double.expects(:set).with("openrouter", "sk-secret").returns(true)
      keychain_double.stubs(:name).returns("libsecret")
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(keychain_double)
      # The local auth.toml routing write fails (e.g. EACCES) *after* the secret
      # is already stored: the message must name the stored-but-unrouted state
      # rather than claiming the store failed or leaking a raw backtrace.
      Xbookmark::Keystore::AuthConfig.any_instance.stubs(:bind_keychain)
        .raises(Errno::EACCES, "auth.toml")

      stdin = StringIO.new("sk-secret\n")
      def stdin.tty?; false; end
      err = run_cli_expect_exit("login", "openrouter", stdin: stdin)
      assert_match(/saved but unrouted/, err)
    end

    it "rejects invalid provider names with a clean exit, not a backtrace" do
      stub_platform_linux
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)

      # parse_provider rescues the Xbookmark::Error and exits 1 instead of
      # letting a raw backtrace escape.
      assert_raises(SystemExit) do
        run_cli("login", "../escape")
      end
    end

    it "picks the macOS Keychain backend when on darwin" do
      stub_platform_macos
      keychain_double = mock("kc")
      keychain_double.expects(:set).with("openrouter", "sk-secret").returns(true)
      keychain_double.stubs(:name).returns("keychain")
      Xbookmark::Keystore::Keychain.stubs(:new).returns(keychain_double)

      stdin = StringIO.new("sk-secret\n")
      def stdin.tty?; false; end
      out, _err = run_cli("login", "openrouter", stdin: stdin)
      assert_match(/Stored openrouter in keychain\./, out)
    end

    it "reads the secret with noecho when stdin is a TTY" do
      stub_platform_linux
      keychain_double = mock("kc")
      keychain_double.expects(:set).with("openrouter", "sk-tty").returns(true)
      keychain_double.stubs(:name).returns("libsecret")
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(keychain_double)

      stdin = StringIO.new("sk-tty\n")
      def stdin.tty?; true; end
      def stdin.noecho; yield(self); end

      out, _err = run_cli("login", "openrouter", stdin: stdin)
      assert_match(/Stored openrouter/, out)
    end
  end

  describe "bind" do
    it "writes the op:// ref to auth.toml" do
      Xbookmark::Keystore::OnePassword.stubs(:available?).returns(false)
      out, _err = run_cli("bind", "openrouter", "op://Personal/OR/cred")
      assert_match(/Bound openrouter to op:/, out)

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      assert_equal "1password", cfg.lookup("openrouter")[:backend]
      assert_equal "op://Personal/OR/cred", cfg.lookup("openrouter")[:ref]
    end

    it "exits non-zero on a malformed reference" do
      assert_raises(SystemExit) { run_cli("bind", "openrouter", "not-a-ref") }
    end

    it "fails fast and does not persist when the op smoke check rejects the ref" do
      Xbookmark::Keystore::OnePassword.stubs(:available?).returns(true)
      op = mock("op")
      op.stubs(:read).raises(Xbookmark::Error, "bad ref")
      Xbookmark::Keystore::OnePassword.stubs(:new).returns(op)

      assert_raises(SystemExit) do
        run_cli("bind", "openrouter", "op://Personal/Missing/cred")
      end

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      assert_nil cfg.lookup("openrouter"), "a rejected ref must not be persisted"
    end

    it "persists without warning when the op smoke check resolves the ref" do
      Xbookmark::Keystore::OnePassword.stubs(:available?).returns(true)
      op = mock("op")
      op.expects(:read).with("op://Personal/OR/cred").returns("sk-verified")
      Xbookmark::Keystore::OnePassword.stubs(:new).returns(op)

      out, err = run_cli("bind", "openrouter", "op://Personal/OR/cred")
      assert_match(/Bound openrouter to op:/, out)
      refute_match(/without verification/, err)
      refute_match(/Refusing to bind/, err)

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      assert_equal "1password", cfg.lookup("openrouter")[:backend]
      assert_equal "op://Personal/OR/cred", cfg.lookup("openrouter")[:ref]
    end

    it "warns but still binds when the op smoke check times out" do
      Xbookmark::Keystore::OnePassword.stubs(:available?).returns(true)
      op = mock("op")
      op.stubs(:read).raises(
        Xbookmark::Keystore::OnePassword::TimeoutError, "op read timed out after 10s"
      )
      Xbookmark::Keystore::OnePassword.stubs(:new).returns(op)

      out, err = run_cli("bind", "openrouter", "op://Personal/Slow/cred")
      assert_match(/Bound openrouter to op:/, out)
      assert_match(/without verification/, err)

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      assert_equal "1password", cfg.lookup("openrouter")[:backend]
    end

    it "warns but still binds when 1Password is installed yet not signed in" do
      Xbookmark::Keystore::OnePassword.stubs(:available?).returns(true)
      op = mock("op")
      op.stubs(:read).raises(
        Xbookmark::Keystore::OnePassword::NotSignedInError, "not signed in"
      )
      Xbookmark::Keystore::OnePassword.stubs(:new).returns(op)

      out, err = run_cli("bind", "openrouter", "op://Personal/Missing/cred")
      assert_match(/Bound openrouter to op:/, out)
      assert_match(/without verification/, err)

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      assert_equal "1password", cfg.lookup("openrouter")[:backend]
    end

    it "deletes the old keychain secret when re-binding a keychain provider to 1Password" do
      stub_platform_linux
      Xbookmark::Keystore::OnePassword.stubs(:available?).returns(false)
      keychain_double = mock("kc")
      # The previously stored keychain secret must be deleted before the op
      # binding is persisted, so the key is not orphaned in the OS keyring.
      keychain_double.expects(:delete).with("openrouter").returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(keychain_double)

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      cfg.bind_keychain("openrouter")

      out, _err = run_cli("bind", "openrouter", "op://Personal/OR/cred")
      assert_match(/Bound openrouter to op:/, out)

      reloaded = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      assert_equal "1password", reloaded.lookup("openrouter")[:backend]
    end

    it "keeps the keychain routing and does not bind when the old secret cannot be deleted" do
      stub_platform_linux
      Xbookmark::Keystore::OnePassword.stubs(:available?).returns(false)
      keychain_double = mock("kc")
      keychain_double.expects(:delete).with("openrouter").returns(false)
      keychain_double.stubs(:name).returns("libsecret")
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(keychain_double)

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      cfg.bind_keychain("openrouter")

      assert_raises(SystemExit) { run_cli("bind", "openrouter", "op://Personal/OR/cred") }

      reloaded = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      assert_equal "keychain", reloaded.lookup("openrouter")[:backend],
        "the op binding must not be persisted while the old secret is orphaned"
    end
  end

  describe "list" do
    it "prints configured providers without echoing values" do
      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      cfg.bind_keychain("x")
      cfg.bind_one_password("openrouter", "op://Personal/OR/cred")
      ENV["XBOOKMARK_ANTHROPIC_KEY"] = "sk-leak"

      out, _err = run_cli("list")
      assert_match(/openrouter\s+1password\s+op:\/\/Personal\/OR\/cred/, out)
      assert_match(/x\s+keychain/, out)
      assert_match(/anthropic\s+env\s+XBOOKMARK_ANTHROPIC_KEY/, out)
      refute_match(/sk-leak/, out)
    ensure
      ENV.delete("XBOOKMARK_ANTHROPIC_KEY")
    end

    it "reports the canonical env var as the source when the legacy alias is also set" do
      ENV.keys.grep(/\AXBOOKMARK_.+_KEY\z/).each { |k| ENV.delete(k) }
      ENV["XBOOKMARK_X_KEY"] = "sk-canonical"
      ENV["XBOOKMARK_X_API_KEY"] = "sk-legacy"

      out, _err = run_cli("list")
      assert_match(/x\s+env\s+XBOOKMARK_X_KEY/, out)
      refute_match(/XBOOKMARK_X_API_KEY/, out)
      refute_match(/sk-/, out)
    ensure
      ENV.delete("XBOOKMARK_X_KEY")
      ENV.delete("XBOOKMARK_X_API_KEY")
    end

    it "falls back to the legacy alias as the source when only it is set" do
      ENV.keys.grep(/\AXBOOKMARK_.+_KEY\z/).each { |k| ENV.delete(k) }
      ENV["XBOOKMARK_X_API_KEY"] = "sk-legacy"

      out, _err = run_cli("list")
      assert_match(/x\s+env\s+XBOOKMARK_X_API_KEY/, out)
      refute_match(/sk-legacy/, out)
    ensure
      ENV.delete("XBOOKMARK_X_API_KEY")
    end

    it "prints 'No providers configured.' when nothing is set" do
      ENV.keys.grep(/\AXBOOKMARK_.+_KEY\z/).each { |k| ENV.delete(k) }
      out, _err = run_cli("list")
      assert_match(/No providers configured/, out)
    end
  end

  describe "show" do
    it "prints the resolved credential via the Resolver" do
      stub_platform_linux
      # The Resolver's keychain probe now mirrors Keystore's D-Bus gate, so a
      # usable-libsecret scenario must present a D-Bus session. Set it
      # explicitly (and restore) rather than depending on the host's ENV, which
      # a headless CI runner may lack.
      orig_dbus = ENV["DBUS_SESSION_BUS_ADDRESS"]
      ENV["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/run/user/1000/bus"
      keychain_double = mock("kc")
      keychain_double.stubs(:get).with("openrouter").returns("sk-resolved")
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(keychain_double)

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      cfg.bind_keychain("openrouter")

      out, _err = run_cli("show", "openrouter")
      assert_match(/sk-resolved/, out)
    ensure
      orig_dbus.nil? ? ENV.delete("DBUS_SESSION_BUS_ADDRESS") : (ENV["DBUS_SESSION_BUS_ADDRESS"] = orig_dbus)
    end

    it "exits non-zero with the actionable hint on stderr when nothing is configured" do
      ENV.keys.grep(/\AXBOOKMARK_.+_KEY\z/).each { |k| ENV.delete(k) }

      # `show` calls exit 1, so run_cli never returns its captured strings;
      # capture stderr directly and assert the missing-credential hint reaches
      # the CLI layer (not just the Resolver).
      captured_stderr = StringIO.new
      orig_stderr = $stderr
      $stderr = captured_stderr
      begin
        assert_raises(SystemExit) { Xbookmark::CLI::Auth.start(["show", "openrouter"]) }
      ensure
        $stderr = orig_stderr
      end

      assert_match(/No credential configured for openrouter/, captured_stderr.string)
      assert_match(/auth login openrouter/, captured_stderr.string)
    end
  end

  describe "rm" do
    it "removes the toml row and the keychain entry" do
      stub_platform_linux
      keychain_double = mock("kc")
      keychain_double.expects(:delete).with("openrouter").returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(keychain_double)

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      cfg.bind_keychain("openrouter")

      out, _err = run_cli("rm", "openrouter")
      assert_match(/Removed openrouter/, out)

      reloaded = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      assert_nil reloaded.lookup("openrouter")
    end

    it "deletes via the macOS Keychain backend on darwin" do
      stub_platform_macos
      keychain_double = mock("kc")
      keychain_double.expects(:delete).with("openrouter").returns(true)
      Xbookmark::Keystore::Keychain.stubs(:new).returns(keychain_double)

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      cfg.bind_keychain("openrouter")

      out, _err = run_cli("rm", "openrouter")
      assert_match(/Removed openrouter/, out)

      reloaded = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      assert_nil reloaded.lookup("openrouter")
    end

    it "is a no-op for an unknown provider" do
      out, _err = run_cli("rm", "openrouter")
      assert_match(/was not configured/, out)
    end

    it "does not touch the keychain when backend is 1password" do
      Xbookmark::Keystore::Libsecret.expects(:new).never
      Xbookmark::Keystore::Keychain.expects(:new).never

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      cfg.bind_one_password("openrouter", "op://Personal/OR/cred")

      out, _err = run_cli("rm", "openrouter")
      assert_match(/Removed openrouter/, out)
    end

    it "keeps the routing when no keychain backend is available to delete the secret" do
      stub_platform_linux
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(false)

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      cfg.bind_keychain("openrouter")

      assert_raises(SystemExit) { run_cli("rm", "openrouter") }

      reloaded = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      refute_nil reloaded.lookup("openrouter"),
        "routing must remain so the keychain secret is not orphaned"
    end

    it "keeps the routing when the keychain delete fails" do
      stub_platform_linux
      keychain_double = mock("kc")
      keychain_double.expects(:delete).with("openrouter").returns(false)
      keychain_double.stubs(:name).returns("libsecret")
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(keychain_double)

      cfg = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      cfg.bind_keychain("openrouter")

      assert_raises(SystemExit) { run_cli("rm", "openrouter") }

      reloaded = Xbookmark::Keystore::AuthConfig.new(path: @auth_toml)
      refute_nil reloaded.lookup("openrouter"),
        "routing must remain when the secret could not be deleted"
    end
  end
end
