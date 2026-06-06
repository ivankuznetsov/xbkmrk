# frozen_string_literal: true

require "test_helper"
require "xbookmark/keystore/resolver"
require "xbookmark/keystore/auth_config"

class FakeBackend
  def initialize(values = {})
    @values = values
  end
  def get(account)
    @values[account.to_s]
  end
end

class FakeOnePassword
  def initialize(values = {})
    @values = values
    @calls = []
  end
  attr_reader :calls
  def read(ref)
    @calls << ref
    @values.fetch(ref) { raise Xbookmark::Error, "missing #{ref}" }
  end
end

describe Xbookmark::Keystore::Resolver do
  def build_config(tmpdir, &block)
    path = File.join(tmpdir, "auth.toml")
    cfg = Xbookmark::Keystore::AuthConfig.new(path: path)
    block&.call(cfg)
    cfg
  end

  before do
    # Clear the deprecation memo so each test sees a clean slate.
    memo = Xbookmark::Keystore::Resolver.const_get(:LEGACY_WARNED)
    memo.clear
  end

  it "returns env var in CI even when auth.toml is populated" do
    Dir.mktmpdir do |dir|
      cfg = build_config(dir) { |c| c.bind_keychain("openrouter") }
      resolver = described_class.new(
        config: cfg,
        env: { "CI" => "true", "XBOOKMARK_OPENROUTER_KEY" => "sk-ci" },
        keychain: FakeBackend.new("openrouter" => "sk-kc")
      )

      assert_equal "sk-ci", resolver.resolve("openrouter")
    end
  end

  it "XBOOKMARK_KEYS_FROM_ENV=1 triggers the env-only shortcut" do
    Dir.mktmpdir do |dir|
      cfg = build_config(dir) { |c| c.bind_keychain("openrouter") }
      resolver = described_class.new(
        config: cfg,
        env: { "XBOOKMARK_KEYS_FROM_ENV" => "1", "XBOOKMARK_OPENROUTER_KEY" => "sk-shortcut" },
        keychain: FakeBackend.new
      )

      assert_equal "sk-shortcut", resolver.resolve("openrouter")
    end
  end

  it "CI mode raises if env var is missing (and does not touch keychain/op)" do
    Dir.mktmpdir do |dir|
      cfg = build_config(dir) { |c| c.bind_keychain("openrouter") }
      keychain = FakeBackend.new("openrouter" => "leaked")
      op = FakeOnePassword.new
      resolver = described_class.new(
        config: cfg, env: { "CI" => "true" },
        keychain: keychain, one_password: op
      )

      err = assert_raises(Xbookmark::Error) { resolver.resolve("openrouter") }
      assert_match(/XBOOKMARK_OPENROUTER_KEY/, err.message)
      assert_empty op.calls
    end
  end

  it "1password routing calls op read with the stored ref" do
    Dir.mktmpdir do |dir|
      cfg = build_config(dir) { |c| c.bind_one_password("openrouter", "op://Personal/OR/cred") }
      op = FakeOnePassword.new("op://Personal/OR/cred" => "sk-op")
      resolver = described_class.new(config: cfg, env: {}, one_password: op)

      assert_equal "sk-op", resolver.resolve("openrouter")
      assert_equal ["op://Personal/OR/cred"], op.calls
    end
  end

  it "keychain routing reads the platform backend by account name" do
    Dir.mktmpdir do |dir|
      cfg = build_config(dir) { |c| c.bind_keychain("openrouter") }
      keychain = FakeBackend.new("openrouter" => "sk-kc")
      resolver = described_class.new(config: cfg, env: {}, keychain: keychain)

      assert_equal "sk-kc", resolver.resolve("openrouter")
    end
  end

  it "env fallback succeeds when no toml entry and no CI flag" do
    Dir.mktmpdir do |dir|
      cfg = build_config(dir)
      resolver = described_class.new(
        config: cfg,
        env: { "XBOOKMARK_OPENROUTER_KEY" => "sk-env" },
        keychain: FakeBackend.new
      )

      assert_equal "sk-env", resolver.resolve("openrouter")
    end
  end

  it "recognises legacy XBOOKMARK_<NAME>_API_KEY form with a deprecation notice" do
    Dir.mktmpdir do |dir|
      cfg = build_config(dir)
      stderr = StringIO.new
      resolver = described_class.new(
        config: cfg,
        env: { "XBOOKMARK_X_API_KEY" => "legacy-key" },
        keychain: FakeBackend.new,
        warn_io: stderr
      )

      assert_equal "legacy-key", resolver.resolve("x")
      assert_match(/XBOOKMARK_X_API_KEY is deprecated/, stderr.string)
      assert_match(/XBOOKMARK_X_KEY/, stderr.string)
    end
  end

  it "raises with both subcommand hints when nothing is configured" do
    Dir.mktmpdir do |dir|
      cfg = build_config(dir)
      resolver = described_class.new(config: cfg, env: {}, keychain: FakeBackend.new)

      err = assert_raises(Xbookmark::Error) { resolver.resolve("openrouter") }
      assert_match(/auth login openrouter/, err.message)
      assert_match(%r{auth bind openrouter op://}, err.message)
    end
  end

  it "raises if auth.toml routes to a backend that returns nothing" do
    Dir.mktmpdir do |dir|
      cfg = build_config(dir) { |c| c.bind_keychain("openrouter") }
      resolver = described_class.new(config: cfg, env: {}, keychain: FakeBackend.new)

      err = assert_raises(Xbookmark::Error) { resolver.resolve("openrouter") }
      assert_match(/keychain/, err.message)
      assert_match(/auth login openrouter/, err.message)
    end
  end

  it "drops an unknown backend from disk and treats the provider as unconfigured" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "auth.toml")
      File.write(path, %([openrouter]\nbackend = "wacky"\n))
      cfg = Xbookmark::Keystore::AuthConfig.new(path: path)
      assert_nil cfg.lookup("openrouter"), "unknown backend should not round-trip"

      resolver = described_class.new(config: cfg, env: {}, keychain: FakeBackend.new)
      err = assert_raises(Xbookmark::Error) { resolver.resolve("openrouter") }
      assert_match(/auth login openrouter/, err.message)
    end
  end

  it "raises a clear error if an in-memory entry still carries an unknown backend" do
    # AuthConfig now filters unknown backends at load time, but the Resolver
    # keeps its defensive else branch for any entry constructed in-memory.
    fake_config = Object.new
    def fake_config.lookup(_provider) = { backend: "wacky" }
    resolver = described_class.new(config: fake_config, env: {}, keychain: FakeBackend.new)

    err = assert_raises(Xbookmark::Error) { resolver.resolve("openrouter") }
    assert_match(/unknown auth.toml backend/, err.message)
  end

  it "accepts a Provider value object directly" do
    Dir.mktmpdir do |dir|
      cfg = build_config(dir)
      resolver = described_class.new(
        config: cfg,
        env: { "XBOOKMARK_OPENROUTER_KEY" => "sk-env" },
        keychain: FakeBackend.new
      )

      assert_equal "sk-env",
        resolver.resolve(Xbookmark::Keystore::Provider.parse("openrouter"))
    end
  end
end
