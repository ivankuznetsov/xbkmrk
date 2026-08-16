# frozen_string_literal: true

require "down"
require "fileutils"
require "uri"
require "digest"
require_relative "variant_picker"

module Xbookmark
  module Media
    class Downloader
      TIMEOUT_SECONDS = 30

      def initialize(timeout: TIMEOUT_SECONDS, max_bytes: nil, http: nil)
        @timeout = timeout
        @max_bytes = max_bytes
        @http = http
      end

      # media_list: array of Xbookmark::X::Media. Returns array of records.
      def download(media_list, dest_dir)
        FileUtils.mkdir_p(dest_dir)
        seen = {}
        media_list.map do |m|
          url, kind = pick_url(m)
          next nil unless url
          path = unique_path(dest_dir, derive_filename(url), seen)
          fetch(url, path)
          {
            path: path,
            kind: kind,
            original_url: url,
            alt_text: m.alt_text,
            media_key: m.media_key,
            width: m.width,
            height: m.height,
            duration_ms: m.duration_ms
          }
        end.compact
      end

      private

      def pick_url(m)
        if m.image?
          [m.url, "photo"]
        elsif m.type == "animated_gif"
          [VariantPicker.best_video_url(m) || m.preview_image_url, "animated_gif"]
        elsif m.type == "video"
          [VariantPicker.best_video_url(m), "video"]
        else
          [nil, m.type]
        end
      end

      def derive_filename(url)
        path = URI.parse(url).path
        base = File.basename(path)
        base = "media-#{Digest::SHA1.hexdigest(url)[0, 8]}" if base.empty?
        base
      end

      def unique_path(dir, base, seen)
        candidate = File.join(dir, base)
        return tap_seen(candidate, seen) unless seen[base] || File.exist?(candidate)
        ext = File.extname(base)
        stem = File.basename(base, ext)
        suffix = Digest::SHA1.hexdigest(base + Time.now.to_f.to_s)[0, 6]
        new_name = "#{stem}-#{suffix}#{ext}"
        tap_seen(File.join(dir, new_name), seen, key: new_name)
      end

      def tap_seen(path, seen, key: nil)
        seen[key || File.basename(path)] = true
        path
      end

      def fetch(url, dest_path)
        if @http
          File.binwrite(dest_path, @http.call(url))
          return
        end
        # X media URLs should be direct CDN assets. Refuse redirects so a
        # trusted archive URL cannot bounce the downloader to a private host.
        options = { open_timeout: @timeout, read_timeout: @timeout, max_redirects: 0 }
        options[:max_size] = @max_bytes if @max_bytes
        tempfile = Down.download(url, **options)
        FileUtils.mv(tempfile.path, dest_path)
      rescue Down::Error => e
        raise MediaError, "media download failed for #{url}: #{e.class}: #{e.message}"
      end
    end
  end
end
