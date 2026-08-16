# frozen_string_literal: true

require "open3"
require "json"
require_relative "registrar"

module Xbookmark
  module Qmd
    class Searcher
      def initialize(config:, runner: nil)
        @config = config
        @runner = runner
      end

      # Returns array of { path:, score:, snippet: }.
      def search(query, limit: 20)
        query_document = structured_query(query)
        argv = [@config.qmd_bin, "query",
                query_document,
                "--no-rerank",
                "--collection", Registrar::COLLECTION_NAME,
                "--limit", limit.to_s,
                "--format", "json"]

        out, err, status = capture(argv)
        unless status_success?(status)
          warn "[xbookmark] qmd query failed: #{err}"
          return []
        end
        parse(out).first(limit.to_i)
      rescue Errno::ENOENT
        warn "[xbookmark] qmd binary not found at #{@config.qmd_bin}; install qmd or set QMD_BIN."
        []
      end

      private

      def capture(argv)
        if @runner
          @runner.call(argv)
        else
          Open3.capture3(*argv)
        end
      end

      def status_success?(status)
        status.respond_to?(:success?) ? status.success? : status == 0
      end

      def structured_query(query)
        text = query.to_s.gsub(/[\r\n]+/, " ").strip
        "lex: #{text}\nvec: #{text}"
      end

      def parse(raw)
        body = raw.strip
        return [] if body.empty?
        json = JSON.parse(body)
        results = json.is_a?(Array) ? json : (json["results"] || json["hits"] || [])
        results.map do |r|
          {
            path: r["path"] || r["file"],
            score: (r["score"] || r["rank"]).to_f,
            snippet: r["snippet"] || r["context"]
          }
        end
      rescue JSON::ParserError => e
        # Surfacing this as a diagnostic — silently returning [] hid qmd
        # output-format breakage as "no matches" for users.
        warn "[xbookmark] qmd output was not JSON: #{e.message}"
        warn "[xbookmark] qmd raw output: #{body[0, 500]}"
        raise
      end
    end
  end
end
