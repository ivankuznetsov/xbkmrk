# frozen_string_literal: true

require "test_helper"
require "xbookmark/keystore/auth_config"

describe Xbookmark::Keystore::AuthConfig do
  def tmp_config_path(dir)
    File.join(dir, "auth.toml")
  end

  it "bind_keychain round-trips through disk" do
    Dir.mktmpdir do |dir|
      path = tmp_config_path(dir)
      cfg = described_class.new(path: path)
      cfg.bind_keychain("x")

      reloaded = described_class.new(path: path)
      entry = reloaded.lookup("x")
      assert_equal "keychain", entry[:backend]
      assert_nil entry[:ref]
    end
  end

  it "bind_one_password round-trips and preserves ref" do
    Dir.mktmpdir do |dir|
      path = tmp_config_path(dir)
      cfg = described_class.new(path: path)
      cfg.bind_one_password("openrouter", "op://Personal/OpenRouter/credential")

      reloaded = described_class.new(path: path)
      entry = reloaded.lookup("openrouter")
      assert_equal "1password", entry[:backend]
      assert_equal "op://Personal/OpenRouter/credential", entry[:ref]
    end
  end

  it "remove of an absent provider returns false" do
    Dir.mktmpdir do |dir|
      cfg = described_class.new(path: tmp_config_path(dir))
      refute cfg.remove("nope")
    end
  end

  it "remove drops the section from disk" do
    Dir.mktmpdir do |dir|
      path = tmp_config_path(dir)
      cfg = described_class.new(path: path)
      cfg.bind_keychain("x")
      cfg.bind_one_password("openrouter", "op://Personal/OR/cred")

      assert cfg.remove("x")
      reloaded = described_class.new(path: path)
      assert_nil reloaded.lookup("x")
      refute_nil reloaded.lookup("openrouter")
    end
  end

  it "writes the file with mode 0600" do
    Dir.mktmpdir do |dir|
      path = tmp_config_path(dir)
      cfg = described_class.new(path: path)
      cfg.bind_keychain("openrouter")

      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  it "rejects 1Password refs that do not start with op://" do
    Dir.mktmpdir do |dir|
      cfg = described_class.new(path: tmp_config_path(dir))
      assert_raises(Xbookmark::Error) do
        cfg.bind_one_password("openrouter", "not-a-ref")
      end
    end
  end

  it "entries returns a defensive copy" do
    Dir.mktmpdir do |dir|
      cfg = described_class.new(path: tmp_config_path(dir))
      cfg.bind_keychain("x")
      copy = cfg.entries
      copy["x"][:backend] = "tampered"

      assert_equal "keychain", cfg.lookup("x")[:backend]
    end
  end

  it "lowercases provider names on lookup and on write" do
    Dir.mktmpdir do |dir|
      path = tmp_config_path(dir)
      cfg = described_class.new(path: path)
      cfg.bind_keychain("OpenRouter")

      assert_equal "keychain", cfg.lookup("openrouter")[:backend]
      assert_match(/^\[openrouter\]/, File.read(path))
    end
  end

  it "ignores malformed sections without crashing" do
    Dir.mktmpdir do |dir|
      path = tmp_config_path(dir)
      File.write(path, "[openrouter]\nbackend = \"keychain\"\n\n[broken]\nnotice = 'no backend'\n")
      cfg = described_class.new(path: path)

      assert_equal "keychain", cfg.lookup("openrouter")[:backend]
      assert_nil cfg.lookup("broken")
    end
  end

  it "accepts a Provider value object via duck-typing on #account" do
    Dir.mktmpdir do |dir|
      path = tmp_config_path(dir)
      cfg = described_class.new(path: path)

      require "xbookmark/keystore/provider"
      provider = Xbookmark::Keystore::Provider.parse("openrouter")
      cfg.bind_keychain(provider)

      assert_equal "keychain", cfg.lookup(provider)[:backend]
      assert_equal "keychain", cfg.lookup("openrouter")[:backend]
    end
  end
end
