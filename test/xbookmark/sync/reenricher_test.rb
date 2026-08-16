# frozen_string_literal: true

require "test_helper"

require "ostruct"
require "tmpdir"
require "fileutils"
require "xbookmark/sync/reenricher"
require "xbookmark/state/store"

describe Xbookmark::Sync::Reenricher do
  # Records every call instead of running codex; returns a done outcome.
  def fake_pipeline
    Class.new do
      attr_reader :processed, :prepared, :finalized

      def initialize
        @processed = []
        @prepared = false
        @finalized = false
      end

      def prepare_run!
        @prepared = true
      end

      def finalize_run!
        @finalized = true
      end

      def process_offline(bookmark, existing_path:, **_kwargs)
        @processed << bookmark.tweet_id
        Xbookmark::Sync::Pipeline::Outcome.new(status: :done, markdown_path: existing_path,
                                               digest: "digest-#{bookmark.tweet_id}", partial: false)
      end
    end.new
  end

  def write_note(vault, name, schema:, tweet_id:)
    path = File.join(vault, "bookmarks", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~MD)
      ---
      xbookmark_schema: #{schema}
      tweet_id: '#{tweet_id}'
      author: alice
      summary: A summary.
      ---

      # Title

      A summary.

      Original tweet text here.

      ## Source

      https://x.com/alice/status/#{tweet_id}
    MD
    path
  end

  it "re-enriches pending notes, skips current-schema notes, and records success" do
    Dir.mktmpdir do |vault|
      write_note(vault, "old-1.md", schema: 1, tweet_id: "1")
      write_note(vault, "old-2.md", schema: 1, tweet_id: "2")
      write_note(vault, "new-3.md", schema: 2, tweet_id: "3")
      store = Xbookmark::State::Store.new(":memory:")
      %w[1 2].each { |id| store.upsert_pending(tweet_id: id, author_handle: "alice", bookmarked_at: "2026-01-01T00:00:00Z") }
      pipeline = fake_pipeline

      report = described_class.new(config: OpenStruct.new(vault_path: vault), store: store, pipeline: pipeline,
                                   logger: ->(_) { }).call

      assert_equal %w[1 2], pipeline.processed.sort
      assert pipeline.prepared, "prepare_run! should run"
      assert pipeline.finalized, "finalize_run! should run"
      assert_equal 2, report.done
      assert_equal 0, report.failed
      assert_equal "digest-1", store.find_bookmark("1")[:enrichment_digest]
    end
  end

  it "resets concept evidence on a fresh full run but not on a limited run" do
    Dir.mktmpdir do |vault|
      write_note(vault, "old-1.md", schema: 1, tweet_id: "1")
      write_note(vault, "old-2.md", schema: 1, tweet_id: "2")
      store = Xbookmark::State::Store.new(":memory:")
      store.upsert_concept(slug: "x", label: "X", kind: "idea", evidence_count: 7)

      described_class.new(config: OpenStruct.new(vault_path: vault), store: store, pipeline: fake_pipeline,
                          logger: ->(_) { }).call(limit: 1)
      assert_equal 7, store.find_concept("x")[:evidence_count], "limited run must not reset evidence"

      described_class.new(config: OpenStruct.new(vault_path: vault), store: store, pipeline: fake_pipeline,
                          logger: ->(_) { }).call
      assert_equal 0, store.find_concept("x")[:evidence_count], "fresh full run resets evidence"
    end
  end

  it "counts failed outcomes and reports a nonzero exit code" do
    Dir.mktmpdir do |vault|
      write_note(vault, "old-1.md", schema: 1, tweet_id: "1")
      store = Xbookmark::State::Store.new(":memory:")
      failing = Class.new do
        def prepare_run!; end
        def finalize_run!; end

        def process_offline(_bookmark, **_kwargs)
          Xbookmark::Sync::Pipeline::Outcome.new(status: :permanent_error, error: RuntimeError.new("boom"))
        end
      end.new

      report = described_class.new(config: OpenStruct.new(vault_path: vault), store: store, pipeline: failing,
                                   logger: ->(_) { }).call

      assert_equal 1, report.failed
      assert_equal 1, report.exit_code
    end
  end

  it "honors an explicit reset_evidence override in both directions" do
    Dir.mktmpdir do |vault|
      write_note(vault, "old-1.md", schema: 1, tweet_id: "1")
      store = Xbookmark::State::Store.new(":memory:")
      store.upsert_concept(slug: "x", label: "X", kind: "idea", evidence_count: 7)

      # Limited run would normally skip the reset; explicit true forces it.
      described_class.new(config: OpenStruct.new(vault_path: vault), store: store, pipeline: fake_pipeline,
                          logger: ->(_) { }).call(limit: 1, reset_evidence: true)
      assert_equal 0, store.find_concept("x")[:evidence_count]

      store.upsert_concept(slug: "x", label: "X", kind: "idea", evidence_count: 7)
      # Fresh full run would normally reset; explicit false skips it.
      described_class.new(config: OpenStruct.new(vault_path: vault), store: store, pipeline: fake_pipeline,
                          logger: ->(_) { }).call(reset_evidence: false)
      assert_equal 7, store.find_concept("x")[:evidence_count]
    end
  end

  it "skips notes whose frontmatter cannot be parsed" do
    Dir.mktmpdir do |vault|
      path = File.join(vault, "bookmarks", "bad.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "---\nkey: [unclosed\n---\nbody\n")
      store = Xbookmark::State::Store.new(":memory:")

      report = described_class.new(config: OpenStruct.new(vault_path: vault), store: store, pipeline: fake_pipeline,
                                   logger: ->(_) { }).call

      assert_equal 1, report.skipped
      assert_equal 0, report.processed
    end
  end

  it "emits a periodic progress log" do
    Dir.mktmpdir do |vault|
      store = Xbookmark::State::Store.new(":memory:")
      Xbookmark::Sync::Reenricher::PROGRESS_EVERY.times do |i|
        write_note(vault, "n#{i}.md", schema: 1, tweet_id: i.to_s)
        store.upsert_pending(tweet_id: i.to_s, author_handle: "a", bookmarked_at: "2026-01-01T00:00:00Z")
      end
      logs = []

      described_class.new(config: OpenStruct.new(vault_path: vault), store: store, pipeline: fake_pipeline,
                          logger: ->(msg) { logs << msg }).call

      n = Xbookmark::Sync::Reenricher::PROGRESS_EVERY
      assert(logs.any? { |m| m.include?("[reenrich] #{n}/#{n}") }, "expected a progress log at #{n}")
    end
  end

  it "builds a default offline pipeline when none is injected" do
    Dir.mktmpdir do |vault|
      store = Xbookmark::State::Store.new(":memory:")
      reenricher = described_class.new(
        config: OpenStruct.new(
          vault_path: vault,
          openrouter_api_key: "router-key",
          openrouter_text_model: Xbookmark::Enrich::OpenRouter::DEFAULT_TEXT_MODEL,
          openrouter_vision_model: Xbookmark::Enrich::OpenRouter::DEFAULT_VISION_MODEL,
          openrouter_image_detail: "low"
        ),
        store: store
      )

      assert_instance_of described_class, reenricher
    end
  end

  it "skips when another run already holds the taxonomy lock" do
    Dir.mktmpdir do |vault|
      write_note(vault, "old-1.md", schema: 1, tweet_id: "1")
      store = Xbookmark::State::Store.new(":memory:")
      held = Xbookmark::Taxonomy::Lock.acquire(vault)
      pipeline = fake_pipeline

      report = described_class.new(config: OpenStruct.new(vault_path: vault), store: store, pipeline: pipeline,
                                   logger: ->(_) { }).call

      assert_equal 0, report.total
      assert_empty pipeline.processed
    ensure
      Xbookmark::Taxonomy::Lock.release(held)
    end
  end

  it "never fetches links offline" do
    assert_nil Xbookmark::Sync::Reenricher::NullLinkFetcher.fetch("https://example.com")
  end
end
