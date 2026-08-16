# frozen_string_literal: true

require "time"
require "set"

require_relative "../enrich/open_router"
require_relative "../enrich/orchestrator"
require_relative "../render/bookmark_renderer"
require_relative "../qmd/registrar"
require_relative "../state/store"
require_relative "../sync/pipeline"
require_relative "../taxonomy/lock"

module Xbookmark
  module Birdclaw
    # Incrementally enriches records already present in a Birdclaw archive.
    # Existing successful tweet IDs are skipped, so reruns only process new or
    # previously failed local records and never trigger a historical X fetch.
    class Importer
      Report = Struct.new(:total, :imported, :skipped, :failed, :partial, keyword_init: true) do
        def to_s
          "birdclaw import: total=#{total} imported=#{imported} skipped=#{skipped} failed=#{failed} partial=#{partial}"
        end

        def exit_code
          failed.to_i.zero? ? 0 : 1
        end
      end

      def initialize(store:, source:, config: nil, pipeline: nil, registrar: nil, logger: nil)
        @store = store
        @source = source
        @config = config
        @pipeline = pipeline || default_pipeline
        @registrar = registrar
        @logger = logger || ->(message) { puts message }
      end

      def call(limit: nil)
        return import_records(limit: limit) unless @config

        lock = Xbookmark::Taxonomy::Lock.acquire(@config.vault_path)
        unless lock
          @logger.call("[birdclaw] another xbookmark run holds the taxonomy lock; skipping")
          return empty_report
        end

        begin
          import_records(limit: limit)
        ensure
          Xbookmark::Taxonomy::Lock.release(lock)
        end
      end

      private

      def import_records(limit:)
        report = empty_report
        prepared = false
        begin
          @pipeline.prepare_run!
          prepared = true
          report.total = index_source_bookmarks
          skipped_ids = terminal_tweet_ids
          attempted = 0
          source_records.each_with_index do |record, index|
            if skipped_ids.include?(record.bookmark.tweet_id)
              report.skipped += 1
              next
            end
            break if limit && attempted >= limit.to_i

            import_record(record, report, index, skipped_ids)
            attempted += 1
          end
        ensure
          @pipeline&.finalize_run! if prepared
        end

        update_store_mode(report, limit: limit)
        @store.set_meta("birdclaw_last_import_at", Time.now.utc.iso8601)
        reindex_qmd if report.imported.positive?
        @logger.call(report.to_s)
        report
      end

      def empty_report
        Report.new(total: 0, imported: 0, skipped: 0, failed: 0, partial: 0)
      end

      def index_source_bookmarks
        total = 0
        source_records.each_slice(100) do |records|
          @pipeline.index_thread_bookmarks(records.map(&:bookmark))
          total += records.size
        end
        total
      end

      def source_records
        @source.each_record(limit: nil)
      end

      def terminal_tweet_ids
        statuses = [Xbookmark::State::Store::STATUS_DONE, Xbookmark::State::Store::STATUS_PERMANENT]
        Set.new(@store.tweet_ids_with_statuses(statuses))
      end

      def import_record(record, report, index, terminal_ids)
        bookmark = record.bookmark
        @store.upsert_pending(
          tweet_id: bookmark.tweet_id,
          author_handle: bookmark.author_handle,
          bookmarked_at: bookmark.bookmarked_at,
          payload: record.payload
        )
        outcome = @pipeline.process(bookmark)
        record_outcome(bookmark, outcome, report)
        terminal_ids << bookmark.tweet_id if outcome.status == :done
        log_progress(report, index + 1)
      end

      def record_outcome(bookmark, outcome, report)
        if outcome.status == :done
          @store.record_success(
            tweet_id: bookmark.tweet_id,
            markdown_path: outcome.markdown_path,
            digest: outcome.digest
          )
          report.imported += 1
          report.partial += 1 if outcome.partial
        else
          permanent = outcome.status == :permanent_error
          @store.record_failure(tweet_id: bookmark.tweet_id, error: outcome.error&.message, permanent: permanent)
          report.failed += 1
        end
      end

      def log_progress(report, processed)
        return unless (processed % 25).zero?

        @logger.call("[birdclaw] #{processed}/#{report.total} imported=#{report.imported} failed=#{report.failed}")
      end

      def update_store_mode(report, limit:)
        if limit
          return if report.imported.zero? && report.failed.zero?

          @store.mode = Xbookmark::State::Store::MODE_BIRDCLAW_PARTIAL
        elsif report.failed.positive?
          @store.mode = Xbookmark::State::Store::MODE_BIRDCLAW_PARTIAL
        elsif report.total.positive?
          @store.mode = Xbookmark::State::Store::MODE_INCREMENTAL
        end
      end

      def reindex_qmd
        return unless @config || @registrar

        registrar = @registrar || Xbookmark::Qmd::Registrar.new(config: @config)
        registrar.ensure_registered! if registrar.respond_to?(:ensure_registered!)
        registrar.index!
      rescue StandardError => e
        warn "[xbookmark] qmd reindex failed: #{e.message}"
      end

      def default_pipeline
        raise ArgumentError, "config is required when pipeline is not injected" unless @config

        llm = Xbookmark::Enrich::OpenRouter.from_config(@config)
        orchestrator = Xbookmark::Enrich::Orchestrator.new(llm: llm)
        renderer = Xbookmark::Render::BookmarkRenderer.new(vault_path: @config.vault_path)
        Xbookmark::Sync::Pipeline.new(config: @config, store: @store, orchestrator: orchestrator, renderer: renderer)
      end
    end
  end
end
