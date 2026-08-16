# frozen_string_literal: true

require "test_helper"

describe Xbookmark::Config do
  before do
    Xbookmark::Paths.stubs(:user_env_path).returns("/nonexistent-xbookmark-user-env")
  end

  it "loads required keys from a project .env" do
    Dir.mktmpdir do |cwd|
      File.write(File.join(cwd, ".env"), "X_CLIENT_ID=abc123\nX_USER_ID=42\n")
      config = described_class.load(cwd: cwd, env: {})
      assert_equal "abc123", config.x_client_id
      assert_equal "42", config.x_user_id
      assert config.env_file.end_with?(".env")
    end
  end

  it "raises ConfigError when X_CLIENT_ID is missing" do
    Dir.mktmpdir do |cwd|
      File.write(File.join(cwd, ".env"), "FOO=bar\n")
      error = assert_raises(Xbookmark::ConfigError) { described_class.load(cwd: cwd, env: {}) }
      assert_match(/X_CLIENT_ID/, error.message)
    end
  end

  it "loads offline config for taxonomy commands without X credentials" do
    Dir.mktmpdir do |cwd|
      File.write(File.join(cwd, ".env"), "XBOOKMARK_WIKI_PATH=/offline/wiki\n")

      config = described_class.load_offline(cwd: cwd, env: {})

      assert_equal "/offline/wiki", config.vault_path
      assert_nil config.x_client_id
      assert_nil config.x_user_id
      assert_equal "codex", config.codex_bin
      assert_equal Xbookmark::Enrich::OpenRouter::DEFAULT_TEXT_MODEL, config.openrouter_text_model
      assert_equal Xbookmark::Enrich::OpenRouter::DEFAULT_VISION_MODEL, config.openrouter_vision_model
      assert_equal "low", config.openrouter_image_detail
      assert_equal "qmd", config.qmd_bin
    end
  end

  it "hydrates OpenRouter credentials for offline enrichment commands" do
    store = Xbookmark::Keystore.new(
      backend: Xbookmark::Keystore::Memory.new("openrouter_api_key" => "stored-router-key")
    )

    Dir.mktmpdir do |cwd|
      config = described_class.load_offline(cwd: cwd, env: {}, keystore: store)

      assert_equal "stored-router-key", config.openrouter_api_key
      assert_nil config.x_client_id
      assert_nil config.x_user_id
    end
  end

  it "uses XDG_DATA_HOME on Linux when set" do
    stub_platform_linux
    Dir.mktmpdir do |cwd|
      File.write(File.join(cwd, ".env"), "X_CLIENT_ID=abc\nX_USER_ID=42\n")
      config = described_class.load(cwd: cwd, env: { "XDG_DATA_HOME" => "/data/xdg" })
      assert_equal "/data/xdg/xbookmark-wiki", config.vault_path
    end
  end

  it "falls back to ~/.local/share on Linux when XDG_DATA_HOME is unset" do
    stub_platform_linux
    with_tmp_home do |home|
      Dir.mktmpdir do |cwd|
        File.write(File.join(cwd, ".env"), "X_CLIENT_ID=abc\nX_USER_ID=42\n")
        config = described_class.load(cwd: cwd, env: {})
        assert_equal File.join(home, ".local", "share", "xbookmark-wiki"), config.vault_path
      end
    end
  end

  it "uses Library/Application Support on macOS by default" do
    stub_platform_macos
    with_tmp_home do |home|
      Dir.mktmpdir do |cwd|
        File.write(File.join(cwd, ".env"), "X_CLIENT_ID=abc\nX_USER_ID=42\n")
        config = described_class.load(cwd: cwd, env: {})
        assert_equal File.join(home, "Library", "Application Support", "xbookmark-wiki"), config.vault_path
      end
    end
  end

  it "honors XBOOKMARK_WIKI_PATH and CLI bookmark wiki override" do
    Dir.mktmpdir do |cwd|
      File.write(File.join(cwd, ".env"), "X_CLIENT_ID=abc\nX_USER_ID=42\nXBOOKMARK_WIKI_PATH=/custom/wiki\n")
      config = described_class.load(cwd: cwd, env: {})
      assert_equal "/custom/wiki", config.vault_path

      File.write(File.join(cwd, ".env"), <<~ENV)
        X_CLIENT_ID=abc
        X_USER_ID=42
        XBOOKMARK_WIKI_PATH=/new/wiki
        XBOOKMARK_VAULT=/legacy/vault
        OBSIDIAN_VAULT_PATH=/legacy/obsidian
      ENV
      precedence = described_class.load(cwd: cwd, env: {})
      assert_equal "/new/wiki", precedence.vault_path

      override = described_class.load(cwd: cwd, env: {}, wiki_override: "/override/wiki", vault_override: "/override/vault")
      assert_equal "/override/wiki", override.vault_path
    end
  end

  it "keeps older vault-named path keys as compatibility aliases" do
    Dir.mktmpdir do |cwd|
      File.write(File.join(cwd, ".env"), "X_CLIENT_ID=abc\nX_USER_ID=42\nXBOOKMARK_VAULT=/legacy/vault\n")
      config = described_class.load(cwd: cwd, env: {})
      assert_equal "/legacy/vault", config.vault_path

      File.write(File.join(cwd, ".env"), "X_CLIENT_ID=abc\nX_USER_ID=42\nOBSIDIAN_VAULT_PATH=/legacy/obsidian\n")
      obsidian = described_class.load(cwd: cwd, env: {})
      assert_equal "/legacy/obsidian", obsidian.vault_path

      override = described_class.load(cwd: cwd, env: {}, vault_override: "/override/vault")
      assert_equal "/override/vault", override.vault_path
    end
  end

  it "ignores blank wiki path values when falling back" do
    stub_platform_linux
    with_tmp_home do |home|
      Dir.mktmpdir do |cwd|
        File.write(File.join(cwd, ".env"), "X_CLIENT_ID=abc\nX_USER_ID=42\nXBOOKMARK_WIKI_PATH=\nXBOOKMARK_VAULT=/legacy/vault\n")
        legacy = described_class.load(cwd: cwd, env: {})
        assert_equal "/legacy/vault", legacy.vault_path

        File.write(File.join(cwd, ".env"), "X_CLIENT_ID=abc\nX_USER_ID=42\nXBOOKMARK_WIKI_PATH=\nXBOOKMARK_VAULT=\nOBSIDIAN_VAULT_PATH=\n")
        default = described_class.load(cwd: cwd, env: {})
        assert_equal File.join(home, ".local", "share", "xbookmark-wiki"), default.vault_path

        override = described_class.load(cwd: cwd, env: {}, wiki_override: "", vault_override: "/override/vault")
        assert_equal "/override/vault", override.vault_path
      end
    end
  end

  it "keeps aux page summaries disabled unless explicitly enabled" do
    Dir.mktmpdir do |cwd|
      File.write(File.join(cwd, ".env"), "X_CLIENT_ID=abc\nX_USER_ID=42\n")
      refute described_class.load(cwd: cwd, env: {}).aux_summaries

      File.write(File.join(cwd, ".env"), "X_CLIENT_ID=abc\nX_USER_ID=42\nXBOOKMARK_AUX_SUMMARIES=true\n")
      assert described_class.load(cwd: cwd, env: {}).aux_summaries
    end
  end

  it "loads an explicit env file before project/user files without overriding existing process values" do
    with_tmp_home do |home|
      explicit_dir = Dir.mktmpdir
      cwd = Dir.mktmpdir
      explicit = File.join(explicit_dir, ".xbookmark.env")
      user_env = File.join(home, ".config", "xbookmark", ".env")
      FileUtils.mkdir_p(File.dirname(user_env))
      File.write(explicit, "X_CLIENT_ID=explicit\nX_USER_ID=from-explicit\nXBOOKMARK_WIKI_PATH=/explicit/wiki\n")
      File.write(File.join(cwd, ".env"), "X_CLIENT_ID=project\nX_USER_ID=from-project\n")
      File.write(user_env, "X_USER_ID=from-user\n")

      config = described_class.load(
        cwd: cwd,
        env: { "XBOOKMARK_ENV_FILE" => explicit, "X_CLIENT_ID" => "process" },
        verbose: true
      )

      assert_equal "process", config.x_client_id
      assert_equal "from-explicit", config.x_user_id
      assert_equal "/explicit/wiki", config.vault_path
      assert_equal explicit, config.env_file
      assert config.verbose
    end
  end

  it "parses optional values defensively and applies macOS log defaults" do
    stub_platform_macos
    with_tmp_home do |home|
      Dir.mktmpdir do |cwd|
        File.write(File.join(cwd, ".env"), <<~ENV)
          X_CLIENT_ID=abc
          X_USER_ID=42
          X_TOKEN_EXPIRES_AT=not-an-int
          XBOOKMARK_MIN_RUN_INTERVAL_HOURS=1.5
          XBOOKMARK_AUX_SUMMARIES=YES
        ENV

        config = described_class.load(cwd: cwd, env: {})

        assert_nil config.x_token_expires_at
        assert_equal 1.5, config.min_run_interval_hours
        assert config.aux_summaries
        assert_equal File.join(home, "Library", "Logs", "xbookmark"), config.logs_dir
      end
    end
  end

  it "honors XDG_STATE_HOME for default logs" do
    stub_platform_linux
    Dir.mktmpdir do |cwd|
      File.write(File.join(cwd, ".env"), "X_CLIENT_ID=abc\nX_USER_ID=42\n")
      config = described_class.load(cwd: cwd, env: { "XDG_STATE_HOME" => "/state" })
      assert_equal "/state/xbookmark", config.logs_dir
    end
  end

  it "hydrates from an explicitly supplied keystore object" do
    store = mock("keystore")
    env = {}
    store.expects(:hydrate).with do |target|
      target["X_CLIENT_ID"] = "abc"
      target["X_USER_ID"] = "42"
      true
    end

    described_class.hydrate_from_keystore!(env, keystore: store)

    assert_equal({ "X_CLIENT_ID" => "abc", "X_USER_ID" => "42" }, env)
  end
end
