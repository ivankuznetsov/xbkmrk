# frozen_string_literal: true

require "json"
require "uri"
require_relative "open_router"
require_relative "link_fetcher"
require_relative "prompt_context"
require_relative "../render/markdown_safety"

module Xbookmark
  module Enrich
    EnrichmentResult = Struct.new(
      :summary, :tags, :concepts, :links,
      :image_captions, :image_ocr, :transcript_summaries,
      :formatted_transcripts, :partial, :link_blobs, :title,
      keyword_init: true
    ) do
      def partial?
        partial == true
      end
    end

    class Orchestrator
      PROMPT_DIR = File.expand_path("prompts", __dir__)
      IMAGE_TIMEOUT = 300

      FINAL_SCHEMA = {
        "type" => "object",
        "required" => %w[tags concepts],
        "properties" => {
          "title" => { "type" => %w[string null] },
          "summary" => { "type" => %w[string null] },
          "tags" => { "type" => "array", "items" => { "type" => "string" } },
          "concepts" => {
            "type" => "array",
            "items" => {
              "type" => "object",
              "required" => %w[label kind],
              "properties" => {
                "label" => { "type" => "string" },
                "kind" => { "type" => "string" },
                "aliases" => { "type" => "array", "items" => { "type" => "string" } },
                "broader" => { "type" => "array", "items" => { "type" => "string" } }
              }
            }
          },
          "links" => { "type" => "array" },
          "image_captions" => { "type" => "object" },
          "image_ocr" => { "type" => "object" },
          "transcript_summaries" => { "type" => "object" },
          "formatted_transcripts" => { "type" => "object" }
        }
      }.freeze

      attr_writer :existing_slugs, :concept_registry

      def initialize(llm: nil, codex: nil, link_fetcher: nil, existing_slugs: [], concept_registry: nil)
        @llm = llm || codex
        raise ArgumentError, "llm is required" unless @llm
        @link_fetcher = link_fetcher || LinkFetcher.new
        @existing_slugs = existing_slugs
        @concept_registry = concept_registry
      end

      # vision: optional pre-computed { "captions" => {...}, "ocr" => {...} }.
      # Offline re-enrichment passes the captions a prior run already produced so
      # the model gets image context as text without a fresh (paid) vision pass.
      def enrich(bookmark, transcripts: {}, image_paths: [], vision: nil)
        link_blobs = fetch_link_blobs(bookmark)
        vision ||= { "captions" => {}, "ocr" => {} }

        partial = false
        final_image_paths = image_paths
        begin
          final = final_call(bookmark, transcripts: transcripts, link_blobs: link_blobs, vision: vision, image_paths: final_image_paths)
        rescue Xbookmark::EnrichmentError, Xbookmark::PermanentError
          raise if Array(image_paths).empty?

          partial = true
          final_image_paths = []
          final = final_call(bookmark, transcripts: transcripts, link_blobs: link_blobs, vision: vision, image_paths: final_image_paths)
        end

        if (final["tags"] || []).empty? || (final["concepts"] || []).empty?
          retried = retry_required_fields(bookmark, transcripts: transcripts, link_blobs: link_blobs, vision: vision, image_paths: final_image_paths)
          if retried && (retried["tags"] || []).any? && (retried["concepts"] || []).any?
            final = retried
          else
            partial = true
            final["tags"] ||= []
            final["concepts"] ||= []
            warn "[xbookmark] enrichment for tweet #{bookmark.tweet_id} returned no tags/concepts after retry; recording partial result"
          end
        end

        EnrichmentResult.new(
          title: title_from(final),
          summary: final["summary"],
          tags: Array(final["tags"]).map(&:to_s),
          concepts: concept_candidates(final["concepts"]),
          links: Array(final["links"] || []),
          image_captions: final["image_captions"] || vision["captions"] || {},
          image_ocr: final["image_ocr"] || vision["ocr"] || {},
          transcript_summaries: string_object(final["transcript_summaries"]),
          formatted_transcripts: string_object(final["formatted_transcripts"]),
          partial: partial,
          link_blobs: link_blobs
        )
      end

      def summarize_topic(slug:, snippets:)
        prompt = render_template("summarize_topic.txt", { slug: slug, snippets: snippets.join("\n---\n") })
        result = @llm.run(prompt: prompt, json_schema: { "type" => "object", "required" => %w[summary] })
        result["summary"]
      end

      def summarize_author(handle:, snippets:)
        prompt = render_template("summarize_author.txt", { handle: handle, snippets: snippets.join("\n---\n") })
        result = @llm.run(prompt: prompt, json_schema: { "type" => "object", "required" => %w[summary] })
        result["summary"]
      end

      private

      # A concise human title for filenames and node labels. Prefers the
      # model's `title`; falls back to the first clause of the summary so old
      # payloads (and offline re-renders) still get a usable title. Sanitized
      # through MarkdownSafety so untrusted text never corrupts a filename or
      # frontmatter value.
      def title_from(final)
        raw = final["title"].to_s.strip
        raw = first_clause(final["summary"]) if raw.empty?
        return nil if raw.empty?

        Xbookmark::Render::MarkdownSafety.wikilink_label(raw)
      end

      def first_clause(summary)
        summary.to_s.split(/[.!?\n]/).first.to_s.strip
      end

      def vision_call(image_paths)
        prompt = render_template("vision.txt", {})
        @llm.run(prompt: prompt, images: image_paths,
                   json_schema: { "type" => "object", "properties" => { "captions" => { "type" => "object" }, "ocr" => { "type" => "object" } } })
      end

      def fetch_link_blobs(bookmark)
        candidate_external_links(bookmark).first(3).filter_map { |url| @link_fetcher.fetch(url) }
      end

      def candidate_external_links(bookmark)
        Array(bookmark.urls).filter_map { |url| expanded_url(url) }.uniq.select { |url| external_article_url?(url) }
      end

      def expanded_url(url)
        return url if url.is_a?(String)
        url[:expanded_url] || url["expanded_url"] || url[:url] || url["url"]
      end

      def external_article_url?(url)
        uri = URI.parse(url.to_s)
        return false unless %w[http https].include?(uri.scheme)
        host = uri.host.to_s.downcase
        return false if host.empty?
        !x_host?(host)
      rescue URI::InvalidURIError
        false
      end

      def x_host?(host)
        host == "x.com" || host.end_with?(".x.com") ||
          host == "twitter.com" || host.end_with?(".twitter.com") ||
          host == "t.co" || host.end_with?(".t.co")
      end

      def final_call(bookmark, transcripts:, link_blobs:, vision:, image_paths:)
        prompt = render_template("final.txt", {
                                   tweet_text: bookmark.text.to_s,
                                   author_handle: bookmark.author_handle.to_s,
                                   quoted_text: (bookmark.quoted_tweet || {})["text"].to_s,
                                   transcripts: transcripts.map { |k, v| "[#{k}]\n#{v}" }.join("\n\n"),
                                   vision_blob: format_vision(vision),
                                   link_blobs: format_link_blobs(link_blobs),
                                   registry_context: registry_context(bookmark)
                                 })
        @llm.run(prompt: prompt, images: image_paths, json_schema: FINAL_SCHEMA, timeout: timeout_for_images(image_paths))
      end

      def retry_required_fields(bookmark, **args)
        prompt_extra = "\n\nIMPORTANT: tags AND concepts arrays MUST contain at least one entry each. " \
                       "Re-derive both from the tweet, transcripts, vision, and link extracts. " \
                       "Return JSON only with the same schema."
        @llm.run(prompt: build_retry_prompt(bookmark, **args, extra: prompt_extra), images: args[:image_paths],
                   json_schema: FINAL_SCHEMA, timeout: timeout_for_images(args[:image_paths]))
      rescue Xbookmark::EnrichmentError, Xbookmark::PermanentError => e
        # Best-effort second pass — fall back to the first call's partial
        # result. A schema mismatch on the retry still leaves the original
        # response usable, but make the failure visible rather than silent.
        warn "[xbookmark] enrichment retry failed for tweet #{bookmark.tweet_id}: #{e.class}: #{e.message}"
        nil
      end

      def build_retry_prompt(bookmark, transcripts:, link_blobs:, vision:, image_paths:, extra:)
        render_template("final.txt", {
                          tweet_text: bookmark.text.to_s,
                          author_handle: bookmark.author_handle.to_s,
                          quoted_text: (bookmark.quoted_tweet || {})["text"].to_s,
                          transcripts: transcripts.map { |k, v| "[#{k}]\n#{v}" }.join("\n\n"),
                          vision_blob: format_vision(vision),
                          link_blobs: format_link_blobs(link_blobs),
                          registry_context: registry_context(bookmark)
                        }) + extra
      end

      def timeout_for_images(image_paths)
        Array(image_paths).empty? ? Xbookmark::Enrich::OpenRouter::DEFAULT_TIMEOUT : IMAGE_TIMEOUT
      end

      def format_vision(vision)
        captions = (vision["captions"] || {}).map { |k, v| "#{k}: #{v}" }.join("\n")
        ocr = (vision["ocr"] || {}).map { |k, v| "#{k}: #{v}" }.join("\n")
        ["captions:\n#{captions}", "ocr:\n#{ocr}"].join("\n")
      end

      def format_link_blobs(blobs)
        blobs.map { |b| "[#{b[:title]}] (#{b[:url]})\n#{b[:text][0, 1500]}" }.join("\n---\n")
      end

      def string_object(value)
        return {} unless value.is_a?(Hash)
        value.each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
      end

      def concept_candidates(values)
        Array(values).first(8).filter_map do |value|
          next { "label" => value.to_s, "kind" => "idea", "aliases" => [], "broader" => [] } unless value.is_a?(Hash)

          label = value["label"] || value[:label] || value["slug"] || value[:slug]
          next if label.to_s.strip.empty?

          {
            "label" => label.to_s,
            "kind" => (value["kind"] || value[:kind] || "idea").to_s,
            "aliases" => Array(value["aliases"] || value[:aliases]).map(&:to_s).first(10),
            "broader" => Array(value["broader"] || value[:broader]).map(&:to_s).first(5)
          }
        end
      end

      def registry_context(bookmark)
        labels = [bookmark.text, bookmark.author_handle].compact
        Xbookmark::Enrich::PromptContext.new(registry: @concept_registry, existing_slugs: @existing_slugs)
          .to_json_for(labels)
      end

      def render_template(name, vars)
        path = File.join(PROMPT_DIR, name)
        File.read(path) % vars
      end
    end
  end
end
