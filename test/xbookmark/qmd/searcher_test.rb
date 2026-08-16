# frozen_string_literal: true

require "test_helper"

require "xbookmark/qmd/searcher"
require "xbookmark/qmd/registrar"

describe Xbookmark::Qmd::Searcher do
  let(:config) do
    Struct::XbookmarkConfig.new(
      vault_path: "/v", state_db_path: ":memory:", logs_dir: "/tmp",
      scratch_dir: "/v/.xbookmark/scratch",
      x_client_id: "c", x_client_secret: nil, x_redirect_uri: "x",
      x_user_id: "42", x_access_token: "t", x_refresh_token: nil,
      x_token_expires_at: nil, codex_bin: "codex",
      whisper_bin: nil, whisper_model: "base.en", qmd_bin: "qmd",
      daily_sync_time: "06:00", min_run_interval_hours: 20.0,
      env_file: nil, verbose: false
    )
  end

  let(:status) do
    Class.new do
      def success?; true; end
      def exitstatus; 0; end
    end.new
  end

  it "parses a JSON array result into hits" do
    json = [
      { "path" => "/v/bookmarks/2026/01/01/1.md", "score" => 0.91, "snippet" => "ozempic dose" },
      { "path" => "/v/bookmarks/2026/01/02/2.md", "score" => 0.55, "snippet" => "another" }
    ].to_json
    runner = ->(_argv) { [json, "", status] }
    hits = described_class.new(config: config, runner: runner).search("ozempic")
    assert_equal 2, hits.size
    assert_equal "/v/bookmarks/2026/01/01/1.md", hits.first[:path]
    assert_in_delta 0.91, hits.first[:score], 0.01
  end

  it "parses a `{results: [...]}` envelope" do
    json = { "results" => [{ "path" => "/v/x.md", "score" => 1, "snippet" => "x" }] }.to_json
    runner = ->(_argv) { [json, "", status] }
    hits = described_class.new(config: config, runner: runner).search("x")
    assert_equal "/v/x.md", hits.first[:path]
  end

  it "enforces the requested limit even when qmd returns extra hits" do
    json = [
      { "path" => "/v/1.md", "score" => 3 },
      { "path" => "/v/2.md", "score" => 2 },
      { "path" => "/v/3.md", "score" => 1 }
    ].to_json
    runner = ->(_argv) { [json, "", status] }
    hits = described_class.new(config: config, runner: runner).search("x", limit: 2)
    assert_equal ["/v/1.md", "/v/2.md"], hits.map { |hit| hit[:path] }
  end

  it "uses structured lexical and vector search without local generation or reranking" do
    argv = nil
    runner = lambda do |command|
      argv = command
      ["[]", "", status]
    end

    described_class.new(config: config, runner: runner).search("first\nsecond", limit: 3)

    assert_equal "qmd", argv[0]
    assert_equal "query", argv[1]
    assert_equal "lex: first second\nvec: first second", argv[2]
    assert_includes argv, "--no-rerank"
    assert_equal ["--collection", "bookmarks"], argv.slice(argv.index("--collection"), 2)
    assert_equal ["--limit", "3"], argv.slice(argv.index("--limit"), 2)
    assert_equal ["--format", "json"], argv.slice(argv.index("--format"), 2)
  end

  it "returns [] when qmd binary is missing" do
    runner = ->(_argv) { raise Errno::ENOENT }
    err = capture_stderr { @hits = described_class.new(config: config, runner: runner).search("x") }
    assert_match(/qmd binary not found/, err)
    assert_equal [], @hits
  end

  it "returns [] and warns when qmd exits unsuccessfully" do
    failing_status = Class.new do
      def success?; false; end
      def exitstatus; 1; end
    end.new
    runner = ->(_argv) { ["", "boom", failing_status] }

    err = capture_stderr { @hits = described_class.new(config: config, runner: runner).search("x") }
    assert_match(/qmd query failed: boom/, err)
    assert_equal [], @hits
  end

  it "parses hits envelopes, rank/context aliases, empty output, and integer statuses" do
    hits_json = { "hits" => [{ "file" => "/v/hit.md", "rank" => "7", "context" => "ctx" }] }.to_json
    runner = ->(_argv) { [hits_json, "", 0] }

    hits = described_class.new(config: config, runner: runner).search("x")

    assert_equal [{ path: "/v/hit.md", score: 7.0, snippet: "ctx" }], hits

    empty = described_class.new(config: config, runner: ->(_argv) { ["", "", 0] }).search("x")
    assert_equal [], empty
  end

  it "raises and diagnoses non-JSON qmd output" do
    runner = ->(_argv) { ["not json", "", status] }
    searcher = described_class.new(config: config, runner: runner)

    err = capture_stderr do
      assert_raises(JSON::ParserError) { searcher.search("x") }
    end
    assert_match(/qmd output was not JSON:.*qmd raw output: not json/m, err)
  end

  it "uses Open3 capture when no runner is injected" do
    searcher = described_class.new(config: config)

    out, err, status = searcher.send(:capture, [RbConfig.ruby, "-e", "STDOUT.write 'ok'; STDERR.write 'err'"])

    assert_equal "ok", out
    assert_equal "err", err
    assert_predicate status, :success?
  end
end
