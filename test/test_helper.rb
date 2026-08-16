# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "tempfile"
require "json"
require "stringio"
require "minitest/autorun" unless ENV["XBOOKMARK_COVERAGE_RUNNER"] == "1"
require "minitest/spec"
require "mocha/minitest"
require "webmock/minitest"

ENV["XBOOKMARK_TEST"] = "1"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "xbookmark"

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

WebMock.disable_net_connect!(allow_localhost: true)

class XbookmarkTest < Minitest::Spec
  def described_class
    current = self.class
    while current.respond_to?(:desc)
      desc = current.desc
      return desc if desc.is_a?(Class) || desc.is_a?(Module)
      current = current.superclass
    end
  end

  def setup
    super
    reset_test_env!
  end

  def teardown
    restore_test_env!
    Xbookmark::Keystore.reset_default! if defined?(Xbookmark::Keystore)
    super
  end

  def reset_test_env!
    @__test_envs__ = {}
    %w[
      XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
      X_CLIENT_ID X_CLIENT_SECRET X_REDIRECT_URI
      X_USER_ID X_ACCESS_TOKEN X_REFRESH_TOKEN X_TOKEN_EXPIRES_AT
      XBOOKMARK_WIKI_PATH XBOOKMARK_VAULT OBSIDIAN_VAULT_PATH
      XBOOKMARK_LOGS_DIR XBOOKMARK_DAILY_TIME
      XBOOKMARK_MIN_RUN_INTERVAL_HOURS XBOOKMARK_TAXONOMY_MAINTENANCE
      OPENROUTER_API_KEY XBOOKMARK_OPENROUTER_KEY OPENROUTER_TEXT_MODEL
      OPENROUTER_VISION_MODEL OPENROUTER_IMAGE_DETAIL BIRDCLAW_DB_PATH
      CODEX_BIN WHISPER_BIN WHISPER_MODEL QMD_BIN PATH
    ].each { |k| @__test_envs__[k] = ENV[k]; ENV.delete(k) }
    require "xbookmark/keystore"
    Xbookmark::Keystore.instance_variable_set(:@default, Xbookmark::Keystore.new(backend: Xbookmark::Keystore::Memory.new))
  end

  def restore_test_env!
    @__test_envs__&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def with_tmp_home
    Dir.mktmpdir("xbookmark-home") do |home|
      orig_home = ENV["HOME"]
      ENV["HOME"] = home
      begin
        yield home
      ensure
        ENV["HOME"] = orig_home
      end
    end
  end

  def stub_platform_linux
    Xbookmark::Paths.stubs(:macos?).returns(false)
    Xbookmark::Paths.stubs(:linux?).returns(true)
  end

  def stub_platform_macos
    Xbookmark::Paths.stubs(:macos?).returns(true)
    Xbookmark::Paths.stubs(:linux?).returns(false)
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  def with_env(overrides)
    old_env = ENV.to_h
    ENV.replace(overrides)
    yield
  ensure
    ENV.replace(old_env)
  end

  def assert_contains_exactly(expected, actual)
    assert_equal expected.sort, actual.sort
  end

  def assert_hash_includes(expected, actual)
    expected.each { |key, value| assert_equal value, actual[key] }
  end

  def process_status(success:, exitstatus: success ? 0 : 1)
    Object.new.tap do |status|
      status.define_singleton_method(:success?) { success }
      status.define_singleton_method(:exitstatus) { exitstatus }
    end
  end

  def fixture_path(*parts)
    File.expand_path(File.join("fixtures", *parts), __dir__)
  end

  def fixture_json(*parts)
    JSON.parse(File.read(fixture_path(*parts)))
  end
end

Minitest::Spec.register_spec_type(/.*/, XbookmarkTest)
