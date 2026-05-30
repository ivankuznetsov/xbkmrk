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

  before do
    @tmpdir = Dir.mktmpdir("xbookmark-auth-cli")
    @auth_toml = File.join(@tmpdir, "auth.toml")
    Xbookmark::Paths.stubs(:default_config_dir).returns(@tmpdir)
  end

  after do
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
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

    it "rejects an empty value" do
      stub_platform_linux
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)
      Xbookmark::Keystore::Libsecret.stubs(:new).returns(mock("kc"))

      stdin = StringIO.new("\n")
      def stdin.tty?; false; end
      assert_raises(SystemExit) { run_cli("login", "openrouter", stdin: stdin) }
    end

    it "rejects invalid provider names" do
      stub_platform_linux
      Xbookmark::Keystore::Libsecret.stubs(:available?).returns(true)

      assert_raises(Xbookmark::Error) do
        run_cli("login", "../escape")
      end
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

    it "warns but does not exit when op smoke check fails" do
      Xbookmark::Keystore::OnePassword.stubs(:available?).returns(true)
      op = mock("op")
      op.stubs(:read).raises(Xbookmark::Error, "bad ref")
      Xbookmark::Keystore::OnePassword.stubs(:new).returns(op)

      out, err = run_cli("bind", "openrouter", "op://Personal/Missing/cred")
      assert_match(/Bound openrouter to op:/, out)
      assert_match(/Warning: bound openrouter but op read failed/, err)
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

    it "prints 'No providers configured.' when nothing is set" do
      ENV.keys.grep(/\AXBOOKMARK_.+_KEY\z/).each { |k| ENV.delete(k) }
      out, _err = run_cli("list")
      assert_match(/No providers configured/, out)
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
  end
end
