# frozen_string_literal: true

require "json"
require "sqlite3"
require "time"
require "uri"

require_relative "../x/expansions"

module Xbookmark
  module Birdclaw
    # Read-only adapter for Birdclaw's local archive. It converts archived
    # bookmark rows into the same payload/bookmark shape used by the X client,
    # allowing an existing corpus to be enriched without a historical API run.
    class Source
      Record = Struct.new(:bookmark, :payload, keyword_init: true)

      PAGE_SIZE = 200
      X_EPOCH_MILLISECONDS = 1_288_834_974_657
      TRUSTED_MEDIA_HOSTS = %w[pbs.twimg.com video.twimg.com].freeze

      QUERY = <<~SQL.freeze
        SELECT tc.tweet_id, tc.collected_at,
               t.author_profile_id, t.text, t.created_at,
               t.entities_json, t.media_json, t.quoted_tweet_id,
               p.handle, p.display_name, p.avatar_url
          FROM tweet_collections tc
          JOIN tweets t ON t.id = tc.tweet_id
          JOIN profiles p ON p.id = t.author_profile_id
         WHERE tc.kind = 'bookmarks'
           AND tc.tweet_id GLOB '[0-9]*'
           AND tc.tweet_id NOT GLOB '*[^0-9]*'
         ORDER BY COALESCE(tc.collected_at, t.created_at) ASC,
                  tc.tweet_id ASC
      SQL

      def initialize(path)
        @path = File.expand_path(path.to_s)
      end

      def records(limit: nil)
        each_record(limit: limit).to_a
      end

      def each_record(limit: nil)
        return enum_for(__method__, limit: limit) unless block_given?

        remaining = limit&.to_i
        return if remaining && remaining <= 0

        offset = 0
        loop do
          page_limit = remaining ? [remaining, PAGE_SIZE].min : PAGE_SIZE
          records = fetch_page(limit: page_limit, offset: offset)
          break if records.empty?

          records.each { |record| yield record }
          offset += records.size
          remaining -= records.size if remaining
          break if records.size < page_limit || remaining&.zero?
        end
      end

      private

      def build_record(row)
        media = media_payload(row)
        tweet = {
          "id" => row["tweet_id"],
          "author_id" => row["author_profile_id"],
          "text" => row["text"],
          "created_at" => row["created_at"],
          "conversation_id" => row["tweet_id"],
          "entities" => entities_payload(row),
          "attachments" => { "media_keys" => media.map { |item| item["media_key"] } }
        }
        if row["quoted_tweet_id"]
          tweet["referenced_tweets"] = [{ "type" => "quoted", "id" => row["quoted_tweet_id"] }]
        end
        payload = {
          "data" => [tweet],
          "includes" => {
            "users" => [{
              "id" => row["author_profile_id"],
              "username" => row["handle"],
              "name" => row["display_name"],
              "profile_image_url" => row["avatar_url"]
            }],
            "media" => media
          },
          "meta" => {}
        }
        bookmark = Xbookmark::X::Expansions.new(payload).bookmarks.fetch(0)
        bookmark.bookmarked_at = bookmark_timestamp(row)
        Record.new(bookmark: bookmark, payload: payload)
      end

      def fetch_page(limit:, offset:)
        db = SQLite3::Database.new(@path, readonly: true)
        db.results_as_hash = true
        db.busy_timeout = 30_000
        db.execute("#{QUERY} LIMIT ? OFFSET ?", [limit, offset]).map { |row| build_record(row) }
      rescue SQLite3::Exception => e
        raise Xbookmark::ConfigError, "Cannot read Birdclaw database #{@path}: #{e.message}"
      ensure
        db&.close
      end

      def bookmark_timestamp(row)
        row["collected_at"] || row["created_at"] || snowflake_timestamp(row["tweet_id"])
      end

      def snowflake_timestamp(tweet_id)
        milliseconds = (tweet_id.to_i >> 22) + X_EPOCH_MILLISECONDS
        Time.at(milliseconds / 1000.0).utc.iso8601(3)
      end

      def entities_payload(row)
        entities = parse_json(row["entities_json"], {})
        urls = Array(entities["urls"]).map do |url|
          {
            "url" => url["url"],
            "expanded_url" => url["expanded_url"] || url["expandedUrl"],
            "display_url" => url["display_url"] || url["displayUrl"],
            "title" => url["title"]
          }
        end
        { "urls" => urls }
      end

      def media_payload(row)
        Array(parse_json(row["media_json"], [])).each_with_index.map do |item, index|
          {
            "media_key" => "birdclaw:#{row['tweet_id']}:#{index}",
            "type" => media_type(item["type"]),
            "url" => trusted_media_url(photo_url(item), hosts: ["pbs.twimg.com"]),
            "preview_image_url" => trusted_media_url(item["thumbnailUrl"] || item["preview_image_url"],
                                                       hosts: ["pbs.twimg.com"]),
            "alt_text" => item["altText"] || item["alt_text"],
            "variants" => variants(item),
            "duration_ms" => item["durationMs"] || item["duration_ms"],
            "width" => item["width"],
            "height" => item["height"]
          }.compact
        end
      end

      def media_type(value)
        case value.to_s
        when "image" then "photo"
        when "gif" then "animated_gif"
        else value.to_s
        end
      end

      def photo_url(item)
        item["url"] if media_type(item["type"]) == "photo"
      end

      def variants(item)
        Array(item["variants"]).map do |variant|
          {
            "url" => trusted_media_url(variant["url"], hosts: ["video.twimg.com"]),
            "content_type" => variant["content_type"] || variant["contentType"],
            "bit_rate" => variant["bit_rate"] || variant["bitRate"]
          }.compact
        end
      end

      def trusted_media_url(raw, hosts: TRUSTED_MEDIA_HOSTS)
        uri = URI.parse(raw.to_s)
        return unless uri.scheme == "https" && hosts.include?(uri.host&.downcase)

        uri.to_s
      rescue URI::InvalidURIError
        nil
      end

      def parse_json(raw, fallback)
        JSON.parse(raw.to_s)
      rescue JSON::ParserError
        fallback
      end
    end
  end
end
