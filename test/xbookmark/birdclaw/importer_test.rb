# frozen_string_literal: true

require "test_helper"

require "ostruct"
require "xbookmark/birdclaw/importer"
require "xbookmark/state/store"
require "xbookmark/taxonomy/lock"
require "xbookmark/x/bookmark"

describe Xbookmark::Birdclaw::Importer do
  Record = Struct.new(:bookmark, :payload, keyword_init: true)

  class RecordSource
    def initialize(records)
      @records = records
    end

    def each_record(limit: nil)
      @records.first(limit || @records.size).each
    end
  end

  class ImportPipeline
    attr_reader :processed

    def initialize(status: :done, partial: false, error: nil)
      @processed = []
      @status = status
      @partial = partial
      @error = error
    end

    def prepare_run!; end
    def finalize_run!; end
    def index_thread_bookmarks(_bookmarks); end

    def process(bookmark)
      @processed << bookmark.tweet_id
      Xbookmark::Sync::Pipeline::Outcome.new(
        status: @status,
        markdown_path: "/wiki/#{bookmark.tweet_id}.md",
        digest: "digest-#{bookmark.tweet_id}",
        partial: @partial,
        error: @error
      )
    end
  end

  it "imports only unseen local records and is idempotent on rerun" do
    store = Xbookmark::State::Store.new(":memory:")
    store.upsert_pending(tweet_id: "1", author_handle: "old", bookmarked_at: Time.now.utc)
    store.record_success(tweet_id: "1", markdown_path: "/wiki/1.md", digest: "old")
    records = %w[1 2].map do |id|
      bookmark = Xbookmark::X::Bookmark.new(
        tweet_id: id, author_handle: "alice", text: "bookmark #{id}", media: [],
        urls: [], bookmarked_at: "2026-08-15T00:00:00Z"
      )
      Record.new(bookmark: bookmark, payload: { "data" => [{ "id" => id }] })
    end
    source = RecordSource.new(records)
    pipeline = ImportPipeline.new
    importer = described_class.new(store: store, source: source, pipeline: pipeline)

    first = importer.call
    second = importer.call(limit: 1)

    assert_equal ["2"], pipeline.processed
    assert_equal 1, first.imported
    assert_equal 1, first.skipped
    assert_equal 0, second.imported
    assert_equal 2, second.skipped
    assert_equal Xbookmark::State::Store::MODE_INCREMENTAL, store.mode
    assert_equal "done", store.find_bookmark("2")[:status]
  end

  it "skips gracefully when another process is writing the same wiki" do
    Dir.mktmpdir do |vault|
      held_lock = Xbookmark::Taxonomy::Lock.acquire(vault)
      config = OpenStruct.new(vault_path: vault)
      importer = described_class.new(
        config: config,
        store: Xbookmark::State::Store.new(":memory:"),
        source: RecordSource.new([]),
        pipeline: ImportPipeline.new
      )

      report = importer.call

      assert_equal 0, report.total
      assert_equal 0, report.exit_code
    ensure
      Xbookmark::Taxonomy::Lock.release(held_lock)
    end
  end

  it "applies limits after terminal rows so bounded reruns advance" do
    store = Xbookmark::State::Store.new(":memory:")
    records = %w[1 2].map do |id|
      bookmark = Xbookmark::X::Bookmark.new(
        tweet_id: id, author_handle: "alice", text: "bookmark #{id}", media: [], urls: [],
        bookmarked_at: "2026-08-15T00:00:00Z"
      )
      Record.new(bookmark: bookmark, payload: { "data" => [{ "id" => id }] })
    end
    pipeline = ImportPipeline.new
    importer = described_class.new(store: store, source: RecordSource.new(records), pipeline: pipeline)

    first = importer.call(limit: 1)
    second = importer.call(limit: 1)

    assert_equal %w[1 2], pipeline.processed
    assert_equal 1, first.imported
    assert_equal 1, second.imported
    assert_equal Xbookmark::State::Store::MODE_BIRDCLAW_PARTIAL, store.mode
  end

  it "preserves retry attempts and skips rows after the terminal attempt" do
    store = Xbookmark::State::Store.new(":memory:")
    bookmark = Xbookmark::X::Bookmark.new(
      tweet_id: "9", author_handle: "alice", text: "retry", media: [], urls: [],
      bookmarked_at: "2026-08-15T00:00:00Z"
    )
    source = RecordSource.new([Record.new(bookmark: bookmark, payload: { "data" => [{ "id" => "9" }] })])
    pipeline = ImportPipeline.new(status: :needs_retry, error: Xbookmark::EnrichmentError.new("later"))
    importer = described_class.new(store: store, source: source, pipeline: pipeline)

    4.times { importer.call }

    assert_equal %w[9 9 9], pipeline.processed
    assert_equal 3, store.find_bookmark("9")[:attempts]
    assert_equal Xbookmark::State::Store::STATUS_PERMANENT, store.find_bookmark("9")[:status]
  end

  it "records terminal failures and returns a non-zero report" do
    store = Xbookmark::State::Store.new(":memory:")
    bookmark = Xbookmark::X::Bookmark.new(
      tweet_id: "9", author_handle: "alice", text: "failed", media: [], urls: [],
      bookmarked_at: "2026-08-15T00:00:00Z"
    )
    source = RecordSource.new([Record.new(bookmark: bookmark, payload: { "data" => [{ "id" => "9" }] })])
    pipeline = ImportPipeline.new(status: :permanent_error, error: Xbookmark::PermanentError.new("bad row"))

    report = described_class.new(store: store, source: source, pipeline: pipeline).call

    assert_equal 1, report.failed
    assert_equal 1, report.exit_code
    assert_equal "permanent_error", store.find_bookmark("9")[:status]
  end

  it "counts partial results and logs bounded progress" do
    store = Xbookmark::State::Store.new(":memory:")
    records = (1..25).map do |id|
      bookmark = Xbookmark::X::Bookmark.new(
        tweet_id: id.to_s, author_handle: "alice", text: "bookmark #{id}", media: [], urls: [],
        bookmarked_at: "2026-08-15T00:00:00Z"
      )
      Record.new(bookmark: bookmark, payload: { "data" => [{ "id" => id.to_s }] })
    end
    messages = []

    report = described_class.new(
      store: store,
      source: RecordSource.new(records),
      pipeline: ImportPipeline.new(partial: true),
      logger: ->(message) { messages << message }
    ).call

    assert_equal 25, report.partial
    assert_equal 0, report.exit_code
    assert messages.any? { |message| message.include?("25/25") }
  end

  it "requires config for its production pipeline" do
    assert_raises(ArgumentError) do
      described_class.new(store: Xbookmark::State::Store.new(":memory:"), source: RecordSource.new([]))
    end
  end

  it "builds the production pipeline from OpenRouter and the configured wiki" do
    Dir.mktmpdir do |vault|
      store = Xbookmark::State::Store.new(":memory:")
      config = OpenStruct.new(vault_path: vault)
      llm = mock("llm")
      orchestrator = mock("orchestrator")
      renderer = mock("renderer")
      pipeline = ImportPipeline.new
      Xbookmark::Enrich::OpenRouter.expects(:from_config).with(config).returns(llm)
      Xbookmark::Enrich::Orchestrator.expects(:new).with(llm: llm).returns(orchestrator)
      Xbookmark::Render::BookmarkRenderer.expects(:new).with(vault_path: vault).returns(renderer)
      Xbookmark::Sync::Pipeline.expects(:new).with(
        config: config, store: store, orchestrator: orchestrator, renderer: renderer
      ).returns(pipeline)

      importer = described_class.new(config: config, store: store, source: RecordSource.new([]))

      assert_equal 0, importer.call.total
    end
  end

  it "refreshes QMD after a successful import" do
    Dir.mktmpdir do |vault|
      store = Xbookmark::State::Store.new(":memory:")
      bookmark = Xbookmark::X::Bookmark.new(
        tweet_id: "7", author_handle: "alice", text: "searchable", media: [], urls: [],
        bookmarked_at: "2026-08-15T00:00:00Z"
      )
      source = RecordSource.new([Record.new(bookmark: bookmark, payload: { "data" => [{ "id" => "7" }] })])
      registrar = mock("registrar")
      registrar.expects(:ensure_registered!).returns(true)
      registrar.expects(:index!).returns(:indexed)

      report = described_class.new(
        config: OpenStruct.new(vault_path: vault), store: store, source: source,
        pipeline: ImportPipeline.new, registrar: registrar
      ).call

      assert_equal 1, report.imported
    end
  end

  it "keeps a successful import when QMD refresh fails" do
    Dir.mktmpdir do |vault|
      store = Xbookmark::State::Store.new(":memory:")
      bookmark = Xbookmark::X::Bookmark.new(
        tweet_id: "8", author_handle: "alice", text: "searchable", media: [], urls: [],
        bookmarked_at: "2026-08-15T00:00:00Z"
      )
      source = RecordSource.new([Record.new(bookmark: bookmark, payload: { "data" => [{ "id" => "8" }] })])
      registrar = stub(ensure_registered!: true)
      registrar.stubs(:index!).raises("qmd down")

      err = capture_stderr do
        @report = described_class.new(
          config: OpenStruct.new(vault_path: vault), store: store, source: source,
          pipeline: ImportPipeline.new, registrar: registrar
        ).call
      end

      assert_equal 1, @report.imported
      assert_includes err, "qmd reindex failed: qmd down"
    end
  end
end
