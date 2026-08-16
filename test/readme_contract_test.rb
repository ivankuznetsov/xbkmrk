# frozen_string_literal: true

require "test_helper"

describe "README setup contract" do
  let(:readme) { File.read(File.expand_path("../README.md", __dir__)) }
  let(:env_example) { File.read(File.expand_path("../.env.example", __dir__)) }
  let(:commands_wiki) { File.read(File.expand_path("../wiki/commands.md", __dir__)) }

  it "points new setups at the implemented scheduler command" do
    assert_includes readme, "bin/xbookmark install"
    refute_includes readme, "bin/xbookmark schedule"
    refute_includes readme, "Ask me whether to install"
  end

  it "does not document deferred commands or config flags as available" do
    deferred_surface = [
      "bin/xbookmark enrich",
      "auth logout",
      "XBOOKMARK_CONFIG",
      "--config PATH",
      "--since YYYY-MM-DD",
      "[--type lex|vec|hyde]",
      "[--json]",
      "minitest"
    ]

    deferred_surface.each do |snippet|
      refute_includes readme, snippet
    end

    assert_includes readme, "bin/xbookmark auth refresh"
  end

  it "keeps the wiki command contract aligned with implemented auth commands" do
    assert_includes commands_wiki, "auth login/status/refresh"
    assert_includes commands_wiki, "`auth refresh` loads config"

    deferred_section = commands_wiki.split("## Deferred Public Surface", 2).last
    refute_includes deferred_section, "- `auth refresh`"
  end

  it "formats auth timestamp examples like the CLI" do
    assert_includes readme, "1789012345 (2026-09-10T03:52:25Z)"
  end

  it "describes the runtime bookmark wiki separately from the project wiki" do
    assert_includes readme, "XBOOKMARK_WIKI_PATH"
    assert_includes readme, "separate from this repository's `wiki/` project LLM wiki"
  end

  it "keeps redirect URI setup tied to env instead of a nonexistent port flag" do
    assert_includes env_example, "X_REDIRECT_URI=http://127.0.0.1:8765/callback"
    refute_includes env_example, "--port"
  end

  it "documents OpenRouter routing without a local Codex runtime requirement" do
    assert_includes readme, "~deepseek/deepseek-v4-flash-latest"
    assert_includes readme, "qwen/qwen3.8-27b"
    assert_includes readme, "No local Codex process"
    refute_includes readme, "codex login"
    refute_includes readme, 'service_tier = "flex"'
    refute_includes readme, 'service_tier = "fast"'
  end

  it "documents update-only import from existing extracted bookmarks" do
    assert_includes readme, "bin/xbookmark import-birdclaw"
    assert_includes readme, "never performs a historical X collection"
    assert_includes commands_wiki, "xbookmark import-birdclaw"
  end

  it "documents scheduled source outages as degraded successful runs" do
    assert_includes readme, "logs `source blocked`"
    assert_includes readme, "cached retry/enrichment work"
    assert_includes readme, "does not stamp the run as completed"
    assert_includes readme, "manual `bin/xbookmark sync` still exits non-zero"
    refute_includes readme, "job exits non-zero and logs the failure"
  end

  it "documents taxonomy repair and concept-first graph output" do
    assert_includes readme, "bin/xbookmark taxonomy audit"
    assert_includes readme, "bin/xbookmark taxonomy rebuild --apply"
    assert_includes readme, "concepts/index.md"
    assert_includes readme, "<readable-slug>-<tweet_id>.md"
    assert_includes commands_wiki, "xbookmark taxonomy audit"
    assert_includes commands_wiki, "xbookmark taxonomy rebuild [--apply]"
  end
end
