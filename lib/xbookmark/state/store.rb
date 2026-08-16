# frozen_string_literal: true

require "sqlite3"
require "fileutils"
require "time"
require "json"
require_relative "migrations"

module Xbookmark
  module State
    # Single-process SQLite state store. All writes happen inside
    # transactions; concurrent processes are rejected via BEGIN IMMEDIATE.
    class Store
      STATUS_PENDING        = "pending"
      STATUS_DONE           = "done"
      STATUS_NEEDS_RETRY    = "needs_retry"
      STATUS_PERMANENT      = "permanent_error"

      MODE_FRESH             = "fresh"
      MODE_TEST_BACKFILLED   = "test_backfilled"
      MODE_FULLY_BACKFILLED  = "fully_backfilled"
      MODE_INCREMENTAL       = "incremental"
      MODE_BIRDCLAW_PARTIAL  = "birdclaw_partial"

      attr_reader :path

      def initialize(path)
        @path = path
        FileUtils.mkdir_p(File.dirname(path)) unless path == ":memory:"
        @db = SQLite3::Database.new(path)
        @db.results_as_hash = true
        @db.busy_timeout = 5_000
        Migrations.apply!(@db)
        ensure_meta_defaults
      end

      def close
        @db&.close
        @db = nil
      end

      # Run a block inside a single SQLite transaction so a failure partway
      # through rolls every write in the block back as one unit. Used by the
      # taxonomy curator to make a batch of concept writes all-or-nothing.
      def transaction(&block)
        @db.transaction(&block)
      end

      # ---- meta ----

      def get_meta(key)
        @db.get_first_value("SELECT value FROM meta WHERE key = ?", [key])
      end

      def set_meta(key, value)
        @db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [key, value.nil? ? nil : value.to_s])
      end

      def mode
        get_meta("mode") || MODE_FRESH
      end

      def mode=(value)
        set_meta("mode", value)
      end

      def cursor
        get_meta("last_pagination_token")
      end

      def cursor=(value)
        set_meta("last_pagination_token", value)
      end

      def last_sync_finished_at
        ts = get_meta("last_sync_finished_at")
        ts ? Time.parse(ts) : nil
      end

      def mark_sync_finished!(time = Time.now.utc)
        set_meta("last_sync_finished_at", time.iso8601)
      end

      def mark_sync_started!(time = Time.now.utc)
        set_meta("last_sync_at", time.iso8601)
      end

      def mark_full_backfill_complete!(time = Time.now.utc)
        set_meta("last_full_backfill_at", time.iso8601)
      end

      # ---- bookmarks ----

      def find_bookmark(tweet_id)
        row = @db.get_first_row("SELECT * FROM bookmarks WHERE tweet_id = ?", [tweet_id.to_s])
        row && symbolize_keys(row)
      end

      def upsert_pending(tweet_id:, author_handle:, bookmarked_at:, payload: nil)
        payload_json = payload ? JSON.generate(payload) : nil
        @db.execute(<<~SQL, [tweet_id.to_s, author_handle.to_s, iso(bookmarked_at), STATUS_PENDING, payload_json])
          INSERT OR IGNORE INTO bookmarks(tweet_id, author_handle, bookmarked_at, status, payload_json)
          VALUES (?, ?, ?, ?, ?)
        SQL
        store_payload!(tweet_id: tweet_id, payload: payload) if payload
      end

      def record_success(tweet_id:, markdown_path:, digest:, time: Time.now.utc)
        @db.execute(<<~SQL, [iso(time), STATUS_DONE, markdown_path.to_s, digest.to_s, tweet_id.to_s])
          UPDATE bookmarks
             SET ingested_at = ?,
                 status = ?,
                 attempts = 0,
                 last_error = NULL,
                 markdown_path = ?,
                 enrichment_digest = ?
           WHERE tweet_id = ?
        SQL
      end

      def record_failure(tweet_id:, error:, permanent: false)
        status = nil
        @db.transaction do
          row = @db.get_first_row("SELECT attempts FROM bookmarks WHERE tweet_id = ?", [tweet_id.to_s])
          attempts = ((row && row["attempts"]) || 0).to_i + 1
          status = permanent || attempts >= 3 ? STATUS_PERMANENT : STATUS_NEEDS_RETRY
          @db.execute(<<~SQL, [status, attempts, error.to_s[0, 4000], tweet_id.to_s])
            UPDATE bookmarks
               SET status = ?,
                   attempts = ?,
                   last_error = ?
             WHERE tweet_id = ?
          SQL
        end
        status
      end

      # Work that can be attempted before asking X for new bookmark pages.
      # `pending` covers rows discovered before an interrupted process, while
      # `needs_retry` covers rows that failed transiently in the pipeline.
      # Cached rows come first so source-blocked scheduler runs still process
      # all locally enrichable work before any uncached row asks X for data.
      def bookmarks_to_process(limit: 100)
        @db.execute(<<~SQL, [STATUS_PENDING, STATUS_NEEDS_RETRY, limit]).map { |r| symbolize_keys(r) }
          SELECT * FROM bookmarks
           WHERE status IN (?, ?)
           ORDER BY CASE WHEN payload_json IS NULL OR payload_json = '' THEN 1 ELSE 0 END,
                    attempts ASC,
                    bookmarked_at DESC
           LIMIT ?
        SQL
      end

      def payload_for(tweet_id)
        raw = @db.get_first_value("SELECT payload_json FROM bookmarks WHERE tweet_id = ?", [tweet_id.to_s])
        return nil if raw.to_s.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end

      def store_payload!(tweet_id:, payload:)
        return if payload.nil?

        @db.execute("UPDATE bookmarks SET payload_json = ? WHERE tweet_id = ?", [JSON.generate(payload), tweet_id.to_s])
      end

      def already_done?(tweet_id)
        row = find_bookmark(tweet_id)
        row && row[:status] == STATUS_DONE
      end

      def tweet_ids_with_statuses(*statuses)
        values = statuses.flatten.compact.map(&:to_s).uniq
        return [] if values.empty?

        placeholders = (["?"] * values.size).join(", ")
        @db.execute("SELECT tweet_id FROM bookmarks WHERE status IN (#{placeholders})", values)
          .map { |row| row["tweet_id"] }
      end

      def reset_to_pending!(tweet_id)
        # Resetting a previously-failed row needs to clear attempts too —
        # otherwise old retry counts carry over and the next failure can
        # tip the row straight into permanent_error.
        @db.execute(<<~SQL, [STATUS_PENDING, tweet_id.to_s])
          UPDATE bookmarks SET status = ?, attempts = 0, last_error = NULL WHERE tweet_id = ?
        SQL
      end

      # ---- pages ----

      def find_page(kind, slug)
        row = @db.get_first_row("SELECT * FROM pages WHERE kind = ? AND slug = ?", [kind, slug])
        row && symbolize_keys(row)
      end

      def upsert_page(kind:, slug:, path:, summary_input_digest: nil, summarized_at: nil)
        @db.execute(<<~SQL, [kind, slug, path, summary_input_digest, iso_or_nil(summarized_at)])
          INSERT INTO pages(kind, slug, path, summary_input_digest, last_summarized_at)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(kind, slug) DO UPDATE SET
            path = excluded.path,
            summary_input_digest = COALESCE(excluded.summary_input_digest, pages.summary_input_digest),
            last_summarized_at = COALESCE(excluded.last_summarized_at, pages.last_summarized_at)
        SQL
      end

      def all_topic_slugs
        @db.execute("SELECT slug FROM pages WHERE kind IN ('topic', 'entity')").map { |r| r["slug"] }
      end

      def concept_slugs
        @db.execute("SELECT slug FROM concepts ORDER BY slug").map { |r| r["slug"] }
      end

      def pages(kind = nil)
        rows =
          if kind
            @db.execute("SELECT * FROM pages WHERE kind = ? ORDER BY slug", [kind])
          else
            @db.execute("SELECT * FROM pages ORDER BY kind, slug")
          end
        rows.map { |r| symbolize_keys(r) }
      end

      def bookmarks
        @db.execute("SELECT * FROM bookmarks ORDER BY bookmarked_at DESC").map { |r| symbolize_keys(r) }
      end

      def concepts
        @db.execute("SELECT * FROM concepts ORDER BY slug").map { |r| symbolize_keys(r) }
      end

      def find_concept(slug)
        row = @db.get_first_row("SELECT * FROM concepts WHERE slug = ?", [slug.to_s])
        row && symbolize_keys(row)
      end

      # Zero every concept's evidence_count. A full offline re-enrichment
      # regenerates every note's concepts, so counts must start from zero to
      # avoid double-counting on top of the original run's additive upserts.
      def reset_concept_evidence!
        @db.execute("UPDATE concepts SET evidence_count = 0")
      end

      def upsert_concept(slug:, label:, kind:, aliases: [], broader: [], facets: [],
                         evidence_count: 0, confidence: 0.0, curator_outcome: "canonical", time: Time.now.utc)
        params = [
          slug.to_s,
          label.to_s,
          kind.to_s,
          JSON.generate(Array(aliases)),
          JSON.generate(Array(broader)),
          JSON.generate(Array(facets)),
          evidence_count.to_i,
          confidence.to_f,
          curator_outcome.to_s,
          iso(time)
        ]
        @db.execute(<<~SQL, params)
          INSERT INTO concepts(slug, label, kind, aliases_json, broader_json, facets_json,
                               evidence_count, confidence, curator_outcome, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(slug) DO UPDATE SET
            label = excluded.label,
            kind = excluded.kind,
            aliases_json = excluded.aliases_json,
            broader_json = excluded.broader_json,
            facets_json = excluded.facets_json,
            evidence_count = concepts.evidence_count + excluded.evidence_count,
            confidence = excluded.confidence,
            curator_outcome = excluded.curator_outcome,
            updated_at = excluded.updated_at
        SQL
      end

      def record_curator_decision(slug:, decision:, time: Time.now.utc)
        @db.execute("INSERT INTO curator_decisions(slug, decision_json, created_at) VALUES (?, ?, ?)",
                    [slug.to_s, JSON.generate(decision), iso(time)])
      end

      def update_bookmark_path!(tweet_id:, markdown_path:)
        @db.execute("UPDATE bookmarks SET markdown_path = ? WHERE tweet_id = ?", [markdown_path.to_s, tweet_id.to_s])
      end

      def rewrite_page_path!(kind:, slug:, path:)
        @db.execute("UPDATE pages SET path = ? WHERE kind = ? AND slug = ?", [path.to_s, kind.to_s, slug.to_s])
      end

      def delete_page!(kind:, slug:)
        @db.execute("DELETE FROM pages WHERE kind = ? AND slug = ?", [kind.to_s, slug.to_s])
      end

      def rename_page!(kind:, old_slug:, new_slug:, path:)
        @db.execute(<<~SQL, [new_slug.to_s, path.to_s, kind.to_s, old_slug.to_s])
          UPDATE pages SET slug = ?, path = ? WHERE kind = ? AND slug = ?
        SQL
      end

      def commit_taxonomy_rebuild!(path_updates:, pruned_ids:, thread_moves: [])
        @db.transaction do
          path_updates.each { |tweet_id, relative| update_bookmark_path!(tweet_id: tweet_id, markdown_path: relative) }
          thread_moves.each do |old_slug, new_slug, relative|
            rename_page!(kind: "thread", old_slug: old_slug, new_slug: new_slug, path: relative)
          end
          pruned_ids.each { |id| delete_page!(kind: "thread", slug: id) }
        end
      end

      private

      def ensure_meta_defaults
        @db.execute("INSERT OR IGNORE INTO meta(key, value) VALUES ('mode', ?)", [MODE_FRESH])
      end

      def iso(value)
        return value if value.is_a?(String)
        return value.iso8601 if value.respond_to?(:iso8601)
        Time.parse(value.to_s).iso8601
      end

      def iso_or_nil(value)
        return nil if value.nil?
        iso(value)
      end

      def symbolize_keys(row)
        row.each_with_object({}) do |(k, v), acc|
          acc[k.to_sym] = v if k.is_a?(String)
        end
      end
    end
  end
end
