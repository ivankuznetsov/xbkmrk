# frozen_string_literal: true

require "test_helper"

require "xbookmark/sync/runner"
require "xbookmark/state/store"

class FakeXClient
  attr_reader :calls

  def initialize(pages: [], single_tweet: nil)
    @pages = pages
    @single_tweet = single_tweet
    @calls = []
  end

  def bookmarks(user_id:, pagination_token: nil, max_results: Xbookmark::X::Client::BOOKMARK_PAGE_SIZE)
    return enum_for(:bookmarks, user_id: user_id, pagination_token: pagination_token, max_results: max_results) unless block_given?
    @calls << { user_id: user_id, pagination_token: pagination_token, max_results: max_results }
    @pages.each { |p| yield p }
  end

  def get_tweet(id)
    @single_tweet || raise("no fake tweet for #{id}")
  end
end

class SourceBlockedClient
  def bookmarks(user_id:, pagination_token: nil, max_results: Xbookmark::X::Client::BOOKMARK_PAGE_SIZE)
    raise Xbookmark::AuthError, "expired"
  end

  def get_tweet(id)
    raise Xbookmark::AuthError, "expired #{id}"
  end
end

class MissingTweetClient
  def bookmarks(user_id:, pagination_token: nil, max_results: Xbookmark::X::Client::BOOKMARK_PAGE_SIZE)
    enum_for(:bookmarks, user_id: user_id, pagination_token: pagination_token, max_results: max_results) unless block_given?
  end

  def get_tweet(_id)
    nil
  end
end

class FakePipeline
  attr_reader :calls, :indexed_pages

  def initialize(behavior)
    @behavior = behavior
    @calls = []
    @indexed_pages = []
    @prepared = false
    @finalized = false
  end

  def prepare_run!
    @prepared = true
  end

  def index_thread_bookmarks(bookmarks)
    @indexed_pages << Array(bookmarks).map(&:tweet_id)
  end

  def process(bookmark)
    @calls << bookmark.tweet_id
    @behavior.call(bookmark)
  end

  def finalize_run!
    @finalized = true
  end
end

class FakeRegistrar
  attr_reader :index_calls

  def initialize
    @index_calls = 0
    @ensure_calls = 0
  end

  def index!
    @index_calls += 1
  end

  def ensure_registered!
    @ensure_calls += 1
  end
end

describe Xbookmark::Sync::Runner do
  let(:store) { Xbookmark::State::Store.new(":memory:") }
  let(:vault) { Dir.mktmpdir }
  let(:config) do
    Struct::XbookmarkConfig.new(
      vault_path: vault,
      state_db_path: ":memory:",
      logs_dir: "/tmp",
      scratch_dir: File.join(vault, ".xbookmark", "scratch"),
      x_client_id: "c", x_client_secret: nil, x_redirect_uri: "x",
      x_user_id: "42", x_access_token: "t", x_refresh_token: nil,
      x_token_expires_at: nil, codex_bin: "codex",
      openrouter_api_key: "router-key",
      openrouter_text_model: Xbookmark::Enrich::OpenRouter::DEFAULT_TEXT_MODEL,
      openrouter_vision_model: Xbookmark::Enrich::OpenRouter::DEFAULT_VISION_MODEL,
      openrouter_image_detail: "low",
      whisper_bin: nil, whisper_model: "base.en", qmd_bin: "qmd",
      daily_sync_time: "06:00", min_run_interval_hours: 20.0,
      env_file: nil, verbose: false
    )
  end

  let(:registrar) { FakeRegistrar.new }

  it "fresh + sync mode prints the bootstrap message and reports a permanent error" do
    fake_client = FakeXClient.new(pages: [])
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: fake_client, pipeline: pipeline, registrar: registrar)
    out = capture_stdout { @report = runner.run(mode: :sync) }
    assert_match(/backfill --limit 100/, out)
    assert_equal 1, @report.permanent_errors
    assert_equal 0, registrar.index_calls
    assert_nil store.last_sync_finished_at
  end

  it "runs taxonomy maintenance during forced scheduled maintenance when enabled" do
    config.taxonomy_maintenance = true
    FileUtils.mkdir_p(File.join(vault, "bookmarks"))
    File.write(File.join(vault, "bookmarks", "123.md"), "body")
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []),
                                 pipeline: FakePipeline.new(->(_) { raise "unused" }), registrar: registrar)

    err = capture_stderr { runner.send(:run_maintenance, force: true) }

    assert_match(/taxonomy: applied/, err)
    assert_equal 1, registrar.index_calls
  end

  it "logs taxonomy maintenance failures without raising" do
    config.taxonomy_maintenance = true
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []),
                                 pipeline: FakePipeline.new(->(_) { raise "unused" }), registrar: registrar)
    Xbookmark::Taxonomy::Rebuilder.stubs(:new).raises("taxonomy down")

    err = capture_stderr { runner.send(:run_maintenance, force: true) }

    assert_match(/taxonomy maintenance failed: RuntimeError: taxonomy down/, err)
    assert_includes store.get_meta("last_taxonomy_error"), "taxonomy down"
  end

  it "surfaces and records a partial_failure taxonomy maintenance result" do
    config.taxonomy_maintenance = true
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []),
                                 pipeline: FakePipeline.new(->(_) { raise "unused" }), registrar: registrar)
    partial = Xbookmark::Taxonomy::Report.new(state: "partial_failure", counts: {}, snapshot_path: "/snap", skipped: ["boom"])
    Xbookmark::Taxonomy::Rebuilder.any_instance.stubs(:call).returns(partial)

    sync_report = Xbookmark::Sync::Report.new
    err = capture_stderr { runner.send(:run_maintenance, force: true, report: sync_report) }

    assert_match(/PARTIAL FAILURE/, err)
    assert_includes store.get_meta("last_taxonomy_error"), "partial_failure"
    assert_equal 1, sync_report.maintenance_errors
    assert_includes sync_report.to_s, "maintenance errors 1"
  end

  it "runs LLM taxonomy curation during local maintenance" do
    config.taxonomy_maintenance = true
    store.upsert_concept(slug: "venezuela-economy", label: "Venezuela Economy", kind: "subtopic",
                         aliases: [], broader: ["venezuela"], facets: ["area/venezuela"],
                         evidence_count: 3, confidence: 0.3)
    codex = mock("codex")
    codex.expects(:run).with do |args|
      args[:timeout] == Xbookmark::Sync::Runner::TAXONOMY_CURATION_TIMEOUT_SECONDS
    end.returns(
      "decisions" => [
        {
          "slug" => "venezuela-economy",
          "label" => "Venezuela Economy",
          "kind" => "subtopic",
          "aliases" => ["Venezuelan economy"],
          "broader" => ["venezuela"],
          "evidence_count" => 3,
          "confidence" => 0.9,
          "curation_state" => "canonical"
        }
      ]
    )
    Xbookmark::Enrich::OpenRouter.stubs(:from_config).returns(codex)
    Xbookmark::Taxonomy::Rebuilder.any_instance.stubs(:call)
      .returns(Xbookmark::Taxonomy::Report.new(state: "clean", counts: {}))
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []),
                                 pipeline: FakePipeline.new(->(_) { raise "unused" }), registrar: registrar)

    runner.send(:run_maintenance, force: true, report: Xbookmark::Sync::Report.new)

    row = store.find_concept("venezuela-economy")
    assert_equal ["Venezuelan economy"], JSON.parse(row[:aliases_json])
    assert_equal 3, row[:evidence_count]
    assert_equal "canonical", row[:curator_outcome]
  end

  it "limits scheduled taxonomy curation to a bounded batch" do
    config.taxonomy_maintenance = true
    60.times do |i|
      store.upsert_concept(slug: "concept-#{i}", label: "Concept #{i}", kind: "entity",
                           evidence_count: 1, confidence: 0.1)
    end
    Xbookmark::Taxonomy::Rebuilder.any_instance.stubs(:call)
      .returns(Xbookmark::Taxonomy::Report.new(state: "clean", counts: {}))
    Xbookmark::Taxonomy::Curator.any_instance.expects(:curate).with do |candidates|
      candidates.size == Xbookmark::Sync::Runner::TAXONOMY_CURATION_BATCH_SIZE
    end.returns([])
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []),
                                 pipeline: FakePipeline.new(->(_) { raise "unused" }), registrar: registrar)

    runner.send(:run_maintenance, force: true, report: Xbookmark::Sync::Report.new)
  end

  it "counts taxonomy curation failures as maintenance errors" do
    config.taxonomy_maintenance = true
    store.upsert_concept(slug: "adhd", label: "ADHD", kind: "idea", evidence_count: 3, confidence: 0.3)
    Xbookmark::Taxonomy::Rebuilder.any_instance.stubs(:call)
      .returns(Xbookmark::Taxonomy::Report.new(state: "clean", counts: {}))
    Xbookmark::Taxonomy::Curator.any_instance.stubs(:curate).raises("curator down")
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []),
                                 pipeline: FakePipeline.new(->(_) { raise "unused" }), registrar: registrar)
    sync_report = Xbookmark::Sync::Report.new

    err = capture_stderr { runner.send(:run_maintenance, force: true, report: sync_report) }

    assert_match(/taxonomy curation failed: RuntimeError: curator down/, err)
    assert_equal 1, sync_report.maintenance_errors
  end

  it "counts and warns on partial enrichment for a synced bookmark" do
    page = {
      "data" => [{ "id" => "t1", "author_id" => "u1", "text" => "x", "created_at" => "2026-01-01T00:00:00Z", "conversation_id" => "c1" }],
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] },
      "meta" => {}
    }
    pipeline = FakePipeline.new(lambda { |_|
      Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d", partial: true)
    })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: [page]),
                                 pipeline: pipeline, registrar: registrar)

    err = capture_stderr { @report = runner.run(mode: :backfill_limited, limit: 1) }

    assert_equal 1, @report.partial
    assert_match(/enriched with incomplete data \(partial\)/, err)
  end

  it "skips the whole run when another holder owns the taxonomy lock" do
    pipeline = FakePipeline.new(->(_) { raise "should not run" })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []),
                                 pipeline: pipeline, registrar: registrar)
    held = Xbookmark::Taxonomy::Lock.acquire(vault)
    begin
      out = capture_stdout { @report = runner.run(mode: :sync) }
    ensure
      Xbookmark::Taxonomy::Lock.release(held)
    end

    assert_match(/holds the taxonomy lock; skipping/, out)
    assert_empty pipeline.calls
  end

  it "backfill --limit 100 stops at exactly N items even when API returns more" do
    page = {
      "data" => Array.new(150) { |i| { "id" => "t#{i}", "author_id" => "u1", "text" => "x", "created_at" => "2026-01-01T00:00:00Z", "conversation_id" => "c#{i}" } },
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] },
      "meta" => {}
    }

    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    fake_client = FakeXClient.new(pages: [page])
    runner = described_class.new(config: config, store: store, x_client: fake_client,
                                 pipeline: pipeline, registrar: registrar)
    report = runner.run(mode: :backfill_limited, limit: 100)
    assert_equal 100, report.synced
    assert_equal 50, fake_client.calls.first[:max_results]
    assert_equal "t0", store.payload_for("t0")["data"].first["id"]
    assert_equal Xbookmark::State::Store::MODE_TEST_BACKFILLED, store.mode
    assert_equal 1, registrar.index_calls
    assert_equal (0...150).map { |i| "t#{i}" }, pipeline.indexed_pages.first
  end

  it "caches only the includes referenced by each bookmark" do
    page = {
      "data" => [
        {
          "id" => "1",
          "author_id" => "u1",
          "text" => "x",
          "created_at" => "2026-01-01T00:00:00Z",
          "conversation_id" => "1",
          "attachments" => { "media_keys" => ["m1"] },
          "referenced_tweets" => [{ "type" => "quoted", "id" => "q1" }]
        }
      ],
      "includes" => {
        "users" => [
          { "id" => "u1", "username" => "alice" },
          { "id" => "u2", "username" => "bob" }
        ],
        "media" => [
          { "media_key" => "m1", "type" => "photo", "url" => "https://x/1.jpg" },
          { "media_key" => "m2", "type" => "photo", "url" => "https://x/2.jpg" }
        ],
        "tweets" => [
          { "id" => "q1", "text" => "quoted" },
          { "id" => "q2", "text" => "unrelated" }
        ]
      },
      "meta" => {}
    }
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: [page]),
                                 pipeline: pipeline, registrar: registrar)

    runner.run(mode: :backfill_limited, limit: 1)

    cached = store.payload_for("1")
    assert_equal ["u1"], cached["includes"]["users"].map { |user| user["id"] }
    assert_equal ["m1"], cached["includes"]["media"].map { |media| media["media_key"] }
    assert_equal ["q1"], cached["includes"]["tweets"].map { |tweet| tweet["id"] }
    rebuilt = Xbookmark::X::Expansions.new(cached).bookmarks.first
    assert_equal "alice", rebuilt.author_handle
    assert_equal "quoted", rebuilt.quoted_tweet["text"]
    assert_equal "m1", rebuilt.media.first.media_key
  end

  it "restores the canonical stored bookmark time for cached retries" do
    payload = {
      "data" => [{ "id" => "1", "author_id" => "u1", "text" => "x",
                   "created_at" => "2025-01-01T00:00:00Z", "conversation_id" => "1" }],
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] },
      "meta" => {}
    }
    runner = described_class.new(
      config: config, store: store, x_client: FakeXClient.new,
      pipeline: FakePipeline.new(->(_) { raise "unused" }), registrar: registrar
    )

    bookmark = runner.send(
      :cached_bookmark,
      payload_json: JSON.generate(payload), bookmarked_at: "2026-08-15T10:11:12Z"
    )

    assert_equal "2026-08-15T10:11:12Z", bookmark.bookmarked_at
    assert_equal "2025-01-01T00:00:00Z", bookmark.created_at
  end

  it "transitions a failure on attempt 1 to success on retry, ordered failed-first on next run" do
    bookmark_payload = {
      "data" => [{ "id" => "1", "author_id" => "u1", "text" => "x", "created_at" => "2026-01-01T00:00:00Z", "conversation_id" => "1" }],
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] },
      "meta" => {}
    }
    single = { "data" => bookmark_payload["data"].first, "includes" => bookmark_payload["includes"] }
    client = FakeXClient.new(pages: [bookmark_payload], single_tweet: single)

    fail_then_pass = FakePipeline.new(->(bm) {
      if bm.tweet_id == "1" && fail_then_pass.calls.size == 1
        Xbookmark::Sync::Pipeline::Outcome.new(status: :needs_retry, error: StandardError.new("boom"))
      else
        Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d")
      end
    })

    runner = described_class.new(config: config, store: store, x_client: client, pipeline: fail_then_pass, registrar: registrar)
    r1 = runner.run(mode: :backfill_limited, limit: 1)
    assert_equal 1, r1.failed

    r2 = runner.run(mode: :backfill_limited, limit: 1)
    assert_equal 1, r2.synced
    assert_equal "done", store.find_bookmark("1")[:status]
  end

  it "retries cached pending and failed bookmarks without calling X" do
    store.mode = Xbookmark::State::Store::MODE_FULLY_BACKFILLED
    payload = fixture_json("x", "bookmarks_page.json")
    first, second = Xbookmark::X::Expansions.new(payload).bookmarks.first(2)
    store.upsert_pending(tweet_id: first.tweet_id, author_handle: first.author_handle, bookmarked_at: first.bookmarked_at,
                         payload: { "data" => [first.raw], "includes" => payload["includes"], "meta" => {} })
    store.upsert_pending(tweet_id: second.tweet_id, author_handle: second.author_handle, bookmarked_at: second.bookmarked_at,
                         payload: { "data" => [second.raw], "includes" => payload["includes"], "meta" => {} })
    store.record_failure(tweet_id: second.tweet_id, error: "codex down")
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })

    runner = described_class.new(config: config, store: store, x_client: SourceBlockedClient.new,
                                 pipeline: pipeline, registrar: registrar)
    report = runner.run(mode: :sync, from_scheduler: true)

    assert_equal 2, report.synced
    assert_equal 1, report.source_errors
    assert_contains_exactly [first.tweet_id, second.tweet_id], pipeline.calls
    assert_equal "done", store.find_bookmark(first.tweet_id)[:status]
    assert_equal "done", store.find_bookmark(second.tweet_id)[:status]
    assert_nil store.last_sync_finished_at
  end

  it "prioritizes cached work ahead of a large uncached backlog during source outages" do
    store.mode = Xbookmark::State::Store::MODE_FULLY_BACKFILLED
    payload = fixture_json("x", "bookmarks_page.json")
    first = Xbookmark::X::Expansions.new(payload).bookmarks.first
    201.times do |i|
      store.upsert_pending(tweet_id: "uncached-#{i}", author_handle: "alice", bookmarked_at: "2026-01-02T00:00:00Z")
    end
    store.upsert_pending(tweet_id: first.tweet_id, author_handle: first.author_handle, bookmarked_at: "2025-01-01T00:00:00Z",
                         payload: { "data" => [first.raw], "includes" => payload["includes"], "meta" => {} })
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: SourceBlockedClient.new,
                                 pipeline: pipeline, registrar: registrar)

    report = runner.run(mode: :sync, from_scheduler: true)

    assert_equal 1, report.synced
    assert_equal [first.tweet_id], pipeline.calls
  end

  it "treats malformed cached payload shapes as cache misses" do
    store.upsert_pending(tweet_id: "1", author_handle: "alice", bookmarked_at: "2026-01-01T00:00:00Z",
                         payload: { "data" => "bad", "includes" => [] })
    store.record_failure(tweet_id: "1", error: "bad cache")
    single = {
      "data" => { "id" => "1", "author_id" => "u1", "text" => "x", "created_at" => "2026-01-01T00:00:00Z", "conversation_id" => "1" },
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] }
    }
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(single_tweet: single),
                                 pipeline: pipeline, registrar: registrar)

    report = runner.run(mode: :backfill_limited, limit: 1)

    assert_equal 1, report.synced
    assert_equal ["1"], pipeline.calls
    assert_equal "1", store.payload_for("1")["data"].first["id"]
  end

  it "treats syntactically corrupt cached payload JSON as a cache miss" do
    store.upsert_pending(tweet_id: "1", author_handle: "alice", bookmarked_at: "2026-01-01T00:00:00Z",
                         payload: { "data" => [] })
    store.record_failure(tweet_id: "1", error: "bad cache")
    store.instance_variable_get(:@db).execute("UPDATE bookmarks SET payload_json = ? WHERE tweet_id = ?", ["{bad", "1"])
    single = {
      "data" => { "id" => "1", "author_id" => "u1", "text" => "x", "created_at" => "2026-01-01T00:00:00Z", "conversation_id" => "1" },
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] }
    }
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(single_tweet: single),
                                 pipeline: pipeline, registrar: registrar)

    report = runner.run(mode: :backfill_limited, limit: 1)

    assert_equal 1, report.synced
    assert_equal ["1"], pipeline.calls
  end

  it "fetches and caches source payloads for retry rows that predate payload storage" do
    store.upsert_pending(tweet_id: "1", author_handle: "alice", bookmarked_at: "2026-01-01T00:00:00Z")
    store.record_failure(tweet_id: "1", error: "old transient")
    single = {
      "data" => { "id" => "1", "author_id" => "u1", "text" => "x", "created_at" => "2026-01-01T00:00:00Z", "conversation_id" => "1" },
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] }
    }
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(single_tweet: single),
                                 pipeline: pipeline, registrar: registrar)

    report = runner.run(mode: :backfill_limited, limit: 1)

    assert_equal 1, report.synced
    assert_equal "1", store.payload_for("1")["data"].first["id"]
    assert_equal ["1"], pipeline.calls
  end

  it "does not process the same retry row again from a source page in one run" do
    store.mode = Xbookmark::State::Store::MODE_FULLY_BACKFILLED
    payload = fixture_json("x", "bookmarks_page.json")
    first = Xbookmark::X::Expansions.new(payload).bookmarks.first
    store.upsert_pending(tweet_id: first.tweet_id, author_handle: first.author_handle, bookmarked_at: first.bookmarked_at,
                         payload: { "data" => [first.raw], "includes" => payload["includes"], "meta" => {} })
    store.record_failure(tweet_id: first.tweet_id, error: "temporary")
    source_page = { "data" => [first.raw], "includes" => payload["includes"], "meta" => {} }
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :needs_retry, error: StandardError.new("still down")) })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: [source_page]),
                                 pipeline: pipeline, registrar: registrar)

    report = runner.run(mode: :sync)

    assert_equal 1, report.failed
    assert_equal [first.tweet_id], pipeline.calls
    assert_equal 2, store.find_bookmark(first.tweet_id)[:attempts]
  end

  it "reports retry rows promoted to permanent as permanent errors" do
    store.mode = Xbookmark::State::Store::MODE_FULLY_BACKFILLED
    payload = fixture_json("x", "bookmarks_page.json")
    first = Xbookmark::X::Expansions.new(payload).bookmarks.first
    store.upsert_pending(tweet_id: first.tweet_id, author_handle: first.author_handle, bookmarked_at: first.bookmarked_at,
                         payload: { "data" => [first.raw], "includes" => payload["includes"], "meta" => {} })
    2.times { store.record_failure(tweet_id: first.tweet_id, error: "temporary") }
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :needs_retry, error: StandardError.new("still down")) })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []),
                                 pipeline: pipeline, registrar: registrar)

    report = runner.run(mode: :sync)

    assert_equal 0, report.failed
    assert_equal 1, report.permanent_errors
    assert_equal "permanent_error", store.find_bookmark(first.tweet_id)[:status]
    assert_equal 1, report.bookmark_attempts
    refute_nil store.last_sync_finished_at
  end

  it "records retry rows whose source tweet is unavailable as permanent" do
    store.upsert_pending(tweet_id: "missing", author_handle: "alice", bookmarked_at: "2026-01-01T00:00:00Z")
    store.record_failure(tweet_id: "missing", error: "old transient")
    pipeline = FakePipeline.new(->(_) { flunk "missing source should not be processed" })
    runner = described_class.new(config: config, store: store, x_client: MissingTweetClient.new,
                                 pipeline: pipeline, registrar: registrar)

    report = runner.run(mode: :backfill_limited, limit: 1)

    assert_equal 0, report.synced
    assert_equal 1, report.permanent_errors
    assert_equal "permanent_error", store.find_bookmark("missing")[:status]
    assert_empty pipeline.calls
  end

  it "skip-if-recent: --from-scheduler exits 0 when the previous finish was < threshold" do
    store.mark_sync_finished!(Time.now.utc - 60) # 1m ago
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []), pipeline: pipeline, registrar: registrar)
    out = capture_stdout { @r = runner.run(mode: :sync, from_scheduler: true) }
    assert_match(/skipping/, out)
    assert_equal 0, @r.synced
  end

  it "skip-if-recent does not fire on a manual sync" do
    store.mode = Xbookmark::State::Store::MODE_INCREMENTAL
    store.mark_sync_finished!(Time.now.utc - 60)
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []), pipeline: pipeline, registrar: registrar)
    runner.run(mode: :sync, from_scheduler: false)
    # No skip output, no error — manual sync runs even when recent.
    assert_equal Xbookmark::State::Store::MODE_INCREMENTAL, store.mode
  end

  it "incremental sync starts from the newest page and stops once a page has no new bookmarks" do
    store.mode = Xbookmark::State::Store::MODE_FULLY_BACKFILLED
    store.cursor = "stale-historical-token"
    store.upsert_pending(tweet_id: "known", author_handle: "alice", bookmarked_at: "2026-01-01T00:00:00Z")
    store.record_success(tweet_id: "known", markdown_path: "/known.md", digest: "d")

    known_page = {
      "data" => [{ "id" => "known", "author_id" => "u1", "text" => "x", "created_at" => "2026-01-01T00:00:00Z", "conversation_id" => "known" }],
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] },
      "meta" => { "next_token" => "older" }
    }
    older_page = {
      "data" => [{ "id" => "older", "author_id" => "u1", "text" => "older", "created_at" => "2025-01-01T00:00:00Z", "conversation_id" => "older" }],
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] },
      "meta" => {}
    }

    fake_client = FakeXClient.new(pages: [known_page, older_page])
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: fake_client, pipeline: pipeline, registrar: registrar)

    report = runner.run(mode: :sync)

    assert_nil fake_client.calls.first[:pagination_token]
    assert_equal 1, report.skipped
    assert_equal 0, report.synced
    assert_empty pipeline.calls
  end

  it "scheduled sync treats blocked X as a source outage and still runs maintenance" do
    store.mode = Xbookmark::State::Store::MODE_FULLY_BACKFILLED
    runner = described_class.new(config: config, store: store, x_client: SourceBlockedClient.new,
                                 pipeline: FakePipeline.new(->(_) { }), registrar: registrar)

    err = capture_stderr { @report = runner.run(mode: :sync, from_scheduler: true) }

    assert_match(/source blocked during new bookmark fetch: expired/, err)
    assert_equal 1, @report.source_errors
    assert_equal 0, @report.permanent_errors
    assert_equal 1, registrar.index_calls
    assert_nil store.last_sync_finished_at
  end

  it "scheduled sync treats X transport failures as source outages" do
    store.mode = Xbookmark::State::Store::MODE_FULLY_BACKFILLED
    client = FakeXClient.new(pages: [])
    client.stubs(:bookmarks).raises(Xbookmark::TransientError, "X API transport failed: execution expired")
    runner = described_class.new(config: config, store: store, x_client: client,
                                 pipeline: FakePipeline.new(->(_) { }), registrar: registrar)

    err = capture_stderr { @report = runner.run(mode: :sync, from_scheduler: true) }

    assert_match(/source blocked during new bookmark fetch: X API transport failed/, err)
    assert_equal 1, @report.source_errors
    assert_equal 0, @report.permanent_errors
    assert_equal 1, registrar.index_calls
  end

  it "manual sync reports blocked X as a command failure without stamping completion" do
    store.mode = Xbookmark::State::Store::MODE_FULLY_BACKFILLED
    runner = described_class.new(config: config, store: store, x_client: SourceBlockedClient.new,
                                 pipeline: FakePipeline.new(->(_) { }), registrar: registrar)

    capture_stderr { @report = runner.run(mode: :sync, from_scheduler: false) }

    assert_equal 1, @report.source_errors
    assert_equal 0, @report.permanent_errors
    assert_equal 0, registrar.index_calls
    assert_nil store.last_sync_finished_at
  end

  it "full backfill marks the store fully backfilled and stamps completion time" do
    stale = File.join(config.scratch_dir, "stale")
    FileUtils.mkdir_p(stale)
    page = {
      "data" => [{ "id" => "1", "author_id" => "u1", "text" => "x", "created_at" => "2026-01-01T00:00:00Z", "conversation_id" => "1" }],
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] },
      "meta" => {}
    }
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: [page]),
                                 pipeline: pipeline, registrar: registrar)

    report = runner.run(mode: :backfill_full)

    assert_equal 1, report.synced
    refute File.exist?(stale)
    assert_equal Xbookmark::State::Store::MODE_FULLY_BACKFILLED, store.mode
    refute_nil store.get_meta("last_full_backfill_at")
    refute_nil store.last_sync_finished_at
  end

  it "incremental sync refuses to run after a limited test backfill" do
    store.mode = Xbookmark::State::Store::MODE_TEST_BACKFILLED
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []), pipeline: pipeline, registrar: registrar)

    out = capture_stdout { @report = runner.run(mode: :sync) }
    assert_match(/test-backfilled/, out)
    assert_equal 1, @report.permanent_errors
    assert_nil store.last_sync_finished_at
  end

  it "incremental sync refuses to run after a limited Birdclaw import" do
    store.mode = Xbookmark::State::Store::MODE_BIRDCLAW_PARTIAL
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []), pipeline: pipeline, registrar: registrar)

    out = capture_stdout { @report = runner.run(mode: :sync) }

    assert_match(/import-birdclaw.*without --limit/, out)
    assert_equal 1, @report.permanent_errors
    assert_nil store.last_sync_finished_at
  end

  it "resyncs one tweet by resetting retry attempts before processing" do
    store.upsert_pending(tweet_id: "1", author_handle: "alice", bookmarked_at: "2026-01-01T00:00:00Z")
    2.times { store.record_failure(tweet_id: "1", error: "old") }
    single = {
      "data" => { "id" => "1", "author_id" => "u1", "text" => "x", "created_at" => "2026-01-01T00:00:00Z", "conversation_id" => "1" },
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] }
    }
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(single_tweet: single),
                                 pipeline: pipeline, registrar: registrar)

    report = runner.run(mode: :resync, tweet_id: "1")

    assert_equal 1, report.synced
    assert_equal 0, store.find_bookmark("1")[:attempts]
    assert_equal "1", store.payload_for("1")["data"].first["id"]
  end

  it "requires tweet_id for resync and rejects unknown modes" do
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: []),
                                 pipeline: FakePipeline.new(->(_) { }), registrar: registrar)

    error = assert_raises(ArgumentError) { runner.run(mode: :resync) }
    assert_match(/tweet_id/, error.message)
    error = assert_raises(ArgumentError) { runner.run(mode: :bogus) }
    assert_match(/unknown mode/, error.message)
  end

  it "records permanent pipeline outcomes and keeps going when QMD reindex fails" do
    page = {
      "data" => [{ "id" => "1", "author_id" => "u1", "text" => "x", "created_at" => "2026-01-01T00:00:00Z", "conversation_id" => "1" }],
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] },
      "meta" => {}
    }
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :permanent_error, error: Xbookmark::PermanentError.new("bad")) })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: [page]),
                                 pipeline: pipeline, registrar: registrar)

    report = runner.run(mode: :backfill_limited, limit: 1)

    assert_equal 1, report.permanent_errors
    assert_equal "permanent_error", store.find_bookmark("1")[:status]
  end

  it "warns but does not fail when QMD reindex raises after a successful sync" do
    page = {
      "data" => [{ "id" => "1", "author_id" => "u1", "text" => "x", "created_at" => "2026-01-01T00:00:00Z", "conversation_id" => "1" }],
      "includes" => { "users" => [{ "id" => "u1", "username" => "alice" }] },
      "meta" => {}
    }
    bad_registrar = Class.new do
      def ensure_registered!
        raise "qmd down"
      end

      def index!
        raise "qmd down"
      end
    end.new
    pipeline = FakePipeline.new(->(_) { Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: "/x", digest: "d") })
    runner = described_class.new(config: config, store: store, x_client: FakeXClient.new(pages: [page]),
                                 pipeline: pipeline, registrar: bad_registrar)

    err = capture_stderr { @report = runner.run(mode: :backfill_limited, limit: 1) }
    assert_match(/qmd reindex failed: qmd down/, err)
    assert_equal 1, @report.synced
  end

  it "reports source errors while retrying failed bookmarks without cached payloads" do
    store.upsert_pending(tweet_id: "1", author_handle: "alice", bookmarked_at: "2026-01-01T00:00:00Z")
    store.record_failure(tweet_id: "1", error: "temporary")
    client = FakeXClient.new(pages: [])
    client.stubs(:get_tweet).raises(Xbookmark::AuthError, "expired")
    runner = described_class.new(config: config, store: store, x_client: client,
                                 pipeline: FakePipeline.new(->(_) { }), registrar: registrar)

    err = capture_stderr { @report = runner.run(mode: :backfill_limited, limit: 1) }
    assert_match(/source blocked during retry: expired/, err)
    assert_equal 1, @report.source_errors
    assert_equal 0, @report.permanent_errors
  end
end
