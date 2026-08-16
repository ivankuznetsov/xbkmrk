# frozen_string_literal: true

require "test_helper"

require "stringio"
require "xbookmark/cli"

describe Xbookmark::CLI::Setup do
  let(:keystore) { Xbookmark::Keystore.new(backend: Xbookmark::Keystore::Memory.new) }
  let(:input_lines) { [] }
  let(:input) do
    str = input_lines.map { |l| "#{l}\n" }.join
    io = StringIO.new(str)
    def io.tty?; true; end
    io
  end
  let(:output) { StringIO.new }
  let(:scheduler) { mock("scheduler").tap { |mock| mock.stubs(:install).returns(true) } }

  before do
    Xbookmark::Paths.stubs(:project_env_path).returns("/nonexistent-project-env")
    Xbookmark::Paths.stubs(:user_env_path).returns("/nonexistent-user-env")
  end

  def run_setup(extra = {})
    described_class.new([], {
      input: input,
      output: output,
      keystore: keystore,
      scheduler: scheduler,
      force_interactive: true
    }.merge(extra)).execute
  end

  it "prompts for every REQUIRED_KEY when keystore is empty" do
    input_lines.replace(["router-key", "abc", "42", "secret", ""])
    run_setup
    assert_equal "abc", keystore.get("X_CLIENT_ID")
    assert_equal "42", keystore.get("X_USER_ID")
    assert_equal "secret", keystore.get("X_CLIENT_SECRET")
    assert_nil keystore.get("X_REDIRECT_URI") # empty input skipped
    assert_equal "router-key", keystore.get("OPENROUTER_API_KEY")
  end

  it "reads secret prompts through noecho when the input supports it" do
    lines = ["router-key\n", "abc\n", "42\n", "secret\n", "\n"]
    secret_input = Object.new
    secret_input.define_singleton_method(:tty?) { true }
    secret_input.define_singleton_method(:gets) { lines.shift }
    secret_input.define_singleton_method(:noecho) { |&block| block.call(self) }

    described_class.new([], {
      input: secret_input,
      output: output,
      keystore: keystore,
      scheduler: scheduler,
      force_interactive: true
    }).execute

    assert_equal "router-key", keystore.get("OPENROUTER_API_KEY")
    assert_equal "secret", keystore.get("X_CLIENT_SECRET")
  end

  it "raises when a required prompt is left blank" do
    input_lines.replace([""])

    error = assert_raises(Xbookmark::ConfigError) { run_setup }
    assert_match(/OPENROUTER_API_KEY/, error.message)
  end

  it "skips prompts for keys already set" do
    keystore.set("X_CLIENT_ID", "preset")
    keystore.set("X_USER_ID", "preset")
    keystore.set("OPENROUTER_API_KEY", "router-key")
    input_lines.replace(["", ""]) # skip remaining optionals
    run_setup
    assert_includes output.string, "X_CLIENT_ID: already set (skipping)"
    assert_includes output.string, "X_USER_ID: already set (skipping)"
  end

  it "imports a legacy .env when present" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_CLIENT_ID=from-env\nX_USER_ID=99\n")
      Xbookmark::Paths.stubs(:project_env_path).returns(env_path)
      Xbookmark::Paths.stubs(:user_env_path).returns("/nonexistent")

      # answers: import? yes, delete file? no, optionals empty
      input_lines.replace(["y", "n", "router-key", "", ""])
      run_setup
      assert_equal "from-env", keystore.get("X_CLIENT_ID")
      assert_equal "99", keystore.get("X_USER_ID")
      assert File.file?(env_path) # not deleted
    end
  end

  it "continues when a legacy .env has no importable keys" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "UNUSED=bar\n")
      Xbookmark::Paths.stubs(:project_env_path).returns(env_path)
      Xbookmark::Paths.stubs(:user_env_path).returns("/nonexistent")

      input_lines.replace(["maybe", "router-key", "abc", "42", "", ""])
      run_setup

      assert_includes output.string, "no known keys found"
      assert_equal "abc", keystore.get("X_CLIENT_ID")
    end
  end

  it "deletes legacy .env after a successful import when user agrees" do
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "X_CLIENT_ID=from-env\nX_USER_ID=99\n")
      Xbookmark::Paths.stubs(:project_env_path).returns(env_path)
      Xbookmark::Paths.stubs(:user_env_path).returns("/nonexistent")

      input_lines.replace(["y", "y", "router-key", "", ""])
      run_setup
      refute File.file?(env_path)
    end
  end

  it "installs the scheduler after setup without another prompt" do
    input_lines.replace(["router-key", "abc", "42", "", ""])
    scheduler.expects(:install).returns(true)
    run_setup
  end

  it "builds the default scheduler installer for configured X sync" do
    keystore.set("OPENROUTER_API_KEY", "router-key")
    keystore.set("X_CLIENT_ID", "abc")
    keystore.set("X_USER_ID", "42")
    input_lines.replace(["", ""])
    config = stub("config")
    Xbookmark::Config.expects(:load).returns(config)
    Xbookmark::Scheduler::Installer.expects(:new).with(config: config).returns(scheduler)

    described_class.new([], {
      input: input, output: output, keystore: keystore, force_interactive: true
    }).execute
  end

  it "supports Birdclaw-only setup without installing the X scheduler" do
    input_lines.replace(["router-key", "", "", "", ""])
    scheduler.expects(:install).never

    assert_equal 0, run_setup
    assert_equal "router-key", keystore.get("OPENROUTER_API_KEY")
    assert_includes output.string, "Birdclaw-only mode"
  end

  it "reports scheduler installation failures without failing setup" do
    input_lines.replace(["router-key", "abc", "42", "", ""])
    scheduler.stubs(:install).raises(StandardError, "no scheduler")

    assert_equal 0, run_setup
    assert_includes output.string, "scheduler install failed: no scheduler"
  end

  it "skips entirely in non-interactive shells" do
    non_tty = StringIO.new("")
    def non_tty.tty?; false; end

    out = StringIO.new
    described_class.new([], {
      input: non_tty,
      output: out,
      keystore: keystore,
      scheduler: scheduler
    }).execute

    assert_includes out.string, "non-interactive shell"
    assert_empty keystore.list_keys
  end

  it "treats tty probe errors as non-interactive" do
    broken_input = Object.new
    broken_input.define_singleton_method(:tty?) { raise "bad tty" }

    described_class.new([], {
      input: broken_input,
      output: output,
      keystore: keystore,
      scheduler: scheduler,
      force_interactive: true
    }).execute

    assert_includes output.string, "non-interactive shell"
  end

  describe ".first_run_check!" do
    it "returns 0 without launching the wizard when keystore is configured" do
      keystore.set("OPENROUTER_API_KEY", "router-key")
      input_io = StringIO.new("")
      def input_io.tty?; true; end
      out = StringIO.new
      assert_equal 0, described_class.first_run_check!(input: input_io, output: out, keystore: keystore)
      assert_empty out.string
    end

    it "returns 0 without launching the wizard when stdin is not a tty" do
      input_io = StringIO.new("")
      def input_io.tty?; false; end
      out = StringIO.new
      assert_equal 0, described_class.first_run_check!(input: input_io, output: out, keystore: keystore)
    end

    it "launches setup when required keys are missing and stdin is a tty" do
      input_lines.replace(["router-key", "", "", "", ""])
      out = StringIO.new
      config = Struct::XbookmarkConfig.new(daily_sync_time: "06:00", logs_dir: "/tmp/logs", env_file: nil)
      Xbookmark::Config.stubs(:load).returns(config)
      Xbookmark::Scheduler::Installer.stubs(:new).returns(scheduler)

      old_test_env = ENV.delete("XBOOKMARK_TEST")
      begin
        assert_equal 0, described_class.first_run_check!(input: input, output: out, keystore: keystore)
        assert_includes out.string, "first run detected"
        assert_equal "router-key", keystore.get("OPENROUTER_API_KEY")
      ensure
        old_test_env ? ENV["XBOOKMARK_TEST"] = old_test_env : ENV.delete("XBOOKMARK_TEST")
      end
    end

    it "treats a complete env file as first-run configured" do
      Dir.mktmpdir do |dir|
        env_path = File.join(dir, ".env")
        File.write(env_path, "OPENROUTER_API_KEY=router-key\n")
        Xbookmark::Paths.stubs(:project_env_path).returns(env_path)
        Xbookmark::Paths.stubs(:user_env_path).returns("/nonexistent")

        assert described_class.first_run_configured?(keystore: keystore)
      end
    end

    it "does not treat an incomplete env file as configured" do
      Dir.mktmpdir do |dir|
        env_path = File.join(dir, ".env")
        File.write(env_path, "X_CLIENT_ID=abc\n")
        Xbookmark::Paths.stubs(:project_env_path).returns(env_path)
        Xbookmark::Paths.stubs(:user_env_path).returns("/nonexistent")

        refute described_class.env_file_configured?
      end
    end

    it "returns false when env file loading raises" do
      Xbookmark::Config.stubs(:load_env_files!).raises(StandardError, "bad env")

      refute described_class.env_file_configured?
    end
  end
end
