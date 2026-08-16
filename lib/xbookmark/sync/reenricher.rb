# frozen_string_literal: true

require "yaml"
require "date"

require_relative "pipeline"
require_relative "../enrich/open_router"
require_relative "../enrich/orchestrator"
require_relative "../enrich/note_source"
require_relative "../render/bookmark_renderer"
require_relative "../taxonomy/lock"

module Xbookmark
  module Sync
    # Offline re-enrichment. Re-runs the current enrichment contract over notes
    # already in the wiki, using the original tweet text + captions preserved in
    # each note (see Enrich::NoteSource) instead of re-fetching from X. Resumable
    # — notes already at the current schema are skipped — and never touches the
    # network (a null link fetcher replaces the live one).
    class Reenricher
      PROGRESS_EVERY = 25

      Report = Struct.new(:total, :processed, :done, :partial, :failed, :skipped, keyword_init: true) do
        def to_s
          "reenrich: total=#{total} processed=#{processed} done=#{done} partial=#{partial} " \
            "failed=#{failed} skipped=#{skipped}"
        end

        def exit_code
          failed.to_i.zero? ? 0 : 1
        end
      end

      # Link fetcher that never touches the network — re-enrichment is offline.
      module NullLinkFetcher
        module_function

        def fetch(_url)
          nil
        end
      end

      def initialize(config:, store:, pipeline: nil, logger: nil, model: nil)
        @config = config
        @store = store
        @model = model
        @pipeline = pipeline || default_pipeline
        @logger = logger || ->(msg) { puts msg }
      end

      def call(limit: nil, reset_evidence: :auto)
        # Hold the taxonomy lock for the whole run so a scheduled sync or a
        # manual `taxonomy rebuild --apply` can't mutate the same files midway.
        lock = Xbookmark::Taxonomy::Lock.acquire(@config.vault_path)
        unless lock
          @logger.call("[reenrich] another xbookmark run holds the taxonomy lock; skipping")
          return Report.new(total: 0, processed: 0, done: 0, partial: 0, failed: 0, skipped: 0)
        end

        begin
          run(limit: limit, reset_evidence: reset_evidence)
        ensure
          Xbookmark::Taxonomy::Lock.release(lock)
        end
      end

      private

      def run(limit:, reset_evidence:)
        pending = pending_notes
        report = Report.new(total: pending.size, processed: 0, done: 0, partial: 0, failed: 0, skipped: 0)
        batch = limit ? pending.first(limit) : pending

        reset_concept_evidence(report, pending: pending, limit: limit) if reset?(reset_evidence, limit, pending)

        @pipeline.prepare_run!
        batch.each_with_index { |path, index| reenrich_one(path, report, index) }
        @pipeline.finalize_run!
        @logger.call(report.to_s)
        report
      end

      def reset?(reset_evidence, limit, pending)
        case reset_evidence
        when true then true
        when false then false
        else limit.nil? && pending.size == all_notes.size # fresh full run only
        end
      end

      def reset_concept_evidence(_report, pending:, limit:)
        @logger.call("[reenrich] fresh full run — resetting concept evidence counts before re-enriching #{pending.size} notes")
        @store.reset_concept_evidence!
      end

      def all_notes
        @all_notes ||= Dir.glob(File.join(@config.vault_path, "bookmarks", "**", "*.md")).sort
      end

      def pending_notes
        all_notes.reject { |path| current_schema?(path) }
      end

      def current_schema?(path)
        raw = File.read(path)
        front = YAML.safe_load(raw.split(/^---\s*$/, 3)[1].to_s, permitted_classes: [Date, Time])
        front.is_a?(Hash) && front["xbookmark_schema"] == Xbookmark::Render::SCHEMA_VERSION
      rescue StandardError
        false
      end

      def reenrich_one(path, report, index)
        parsed = Xbookmark::Enrich::NoteSource.parse(path, vault_path: @config.vault_path)
        unless parsed
          report.skipped += 1
          return
        end

        report.processed += 1
        outcome = @pipeline.process_offline(
          parsed.bookmark,
          transcripts: parsed.transcripts,
          image_paths: parsed.image_paths,
          media_records: parsed.media_records,
          vision: parsed.vision,
          existing_path: path
        )
        record(parsed.bookmark, outcome, report)
        log_progress(report, index)
      end

      def record(bookmark, outcome, report)
        case outcome.status
        when :done
          @store.record_success(tweet_id: bookmark.tweet_id, markdown_path: outcome.markdown_path,
                                digest: outcome.digest)
          outcome.partial ? report.partial += 1 : report.done += 1
        else
          report.failed += 1
          warn "[xbookmark] reenrich failed for #{bookmark.tweet_id}: #{outcome.error&.class}: #{outcome.error&.message}"
        end
      end

      def log_progress(report, index)
        return unless ((index + 1) % PROGRESS_EVERY).zero?

        @logger.call("[reenrich] #{report.processed}/#{report.total} (done=#{report.done} " \
                     "partial=#{report.partial} failed=#{report.failed})")
      end

      def default_pipeline
        llm = Xbookmark::Enrich::OpenRouter.from_config(@config, text_model: @model)
        orchestrator = Xbookmark::Enrich::Orchestrator.new(llm: llm, link_fetcher: NullLinkFetcher)
        renderer = Xbookmark::Render::BookmarkRenderer.new(vault_path: @config.vault_path)
        Pipeline.new(config: @config, store: @store, orchestrator: orchestrator, renderer: renderer)
      end
    end
  end
end
