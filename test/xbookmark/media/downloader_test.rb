# frozen_string_literal: true

require "test_helper"

require "xbookmark/media/downloader"
require "xbookmark/x/bookmark"
require "tempfile"

describe Xbookmark::Media::Downloader do
  let(:photo) do
    Xbookmark::X::Media.new(media_key: "m1", type: "photo", url: "https://x/img.jpg",
                            variants: [], duration_ms: nil)
  end

  let(:video) do
    Xbookmark::X::Media.new(
      media_key: "v1", type: "video",
      variants: [
        { "bit_rate" => 320_000, "content_type" => "video/mp4", "url" => "https://x/low.mp4" },
        { "bit_rate" => 832_000, "content_type" => "video/mp4", "url" => "https://x/hi.mp4" },
        { "content_type" => "application/x-mpegURL", "url" => "https://x/playlist.m3u8" }
      ],
      duration_ms: 10_000
    )
  end

  it "downloads an image to the destination directory" do
    Dir.mktmpdir do |dir|
      stub = ->(_) { "imagebytes" }
      records = described_class.new(http: stub).download([photo], dir)
      assert_equal 1, records.size
      assert_equal "imagebytes", File.read(records.first[:path])
      assert_equal "photo", records.first[:kind]
    end
  end

  it "picks the highest-bitrate mp4 variant for a video" do
    Dir.mktmpdir do |dir|
      seen = []
      stub = ->(url) { seen << url; "videobytes" }
      records = described_class.new(http: stub).download([video], dir)
      assert_equal ["https://x/hi.mp4"], seen
      assert_equal "video", records.first[:kind]
    end
  end

  it "uniquifies filenames when two media share a basename" do
    media_a = Xbookmark::X::Media.new(media_key: "a", type: "photo", url: "https://x/foo/img.jpg", variants: [])
    media_b = Xbookmark::X::Media.new(media_key: "b", type: "photo", url: "https://x/bar/img.jpg", variants: [])
    Dir.mktmpdir do |dir|
      stub = ->(url) { "bytes-#{url}" }
      records = described_class.new(http: stub).download([media_a, media_b], dir)
      assert_equal 2, records.map { |r| r[:path] }.uniq.size
    end
  end

  it "raises MediaError on a Down failure" do
    bad = Xbookmark::X::Media.new(media_key: "x", type: "photo", url: "https://x/missing.jpg", variants: [])
    Dir.mktmpdir do |dir|
      stub_request(:get, "https://x/missing.jpg").to_return(status: 404)
      assert_raises(Xbookmark::MediaError) { described_class.new.download([bad], dir) }
    end
  end

  it "does not impose a download size cap by default" do
    tempfile = Tempfile.new("xbookmark-media")
    tempfile.write("large")
    tempfile.flush

    Down.expects(:download)
      .with("https://x/hi.mp4", open_timeout: 30, read_timeout: 30, max_redirects: 0)
      .returns(tempfile)

    Dir.mktmpdir do |dir|
      described_class.new.download([video], dir)
    end
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  it "passes an explicit download size cap when configured" do
    tempfile = Tempfile.new("xbookmark-media")
    tempfile.write("capped")
    tempfile.flush

    Down.expects(:download)
      .with("https://x/hi.mp4", open_timeout: 30, read_timeout: 30, max_redirects: 0, max_size: 123)
      .returns(tempfile)

    Dir.mktmpdir do |dir|
      described_class.new(max_bytes: 123).download([video], dir)
    end
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  it "downloads animated GIF videos, falls back to previews, and skips unknown media types" do
    gif_with_variant = Xbookmark::X::Media.new(
      media_key: "g1",
      type: "animated_gif",
      preview_image_url: "https://x/preview.jpg",
      variants: [{ "content_type" => "video/mp4", "url" => "https://x/gif.mp4" }]
    )
    gif_preview = Xbookmark::X::Media.new(
      media_key: "g2",
      type: "animated_gif",
      preview_image_url: "https://x/fallback.jpg",
      variants: []
    )
    unknown = Xbookmark::X::Media.new(media_key: "u", type: "poll", variants: [])

    Dir.mktmpdir do |dir|
      seen = []
      records = described_class.new(http: ->(url) { seen << url; "bytes" }).download([gif_with_variant, gif_preview, unknown], dir)

      assert_equal ["https://x/gif.mp4", "https://x/fallback.jpg"], seen
      assert_equal %w[animated_gif animated_gif], records.map { |record| record[:kind] }
    end
  end

  it "derives a stable fallback filename when a media URL has no basename" do
    nameless = Xbookmark::X::Media.new(media_key: "m", type: "photo", url: "https://x", variants: [])

    Dir.mktmpdir do |dir|
      records = described_class.new(http: ->(_) { "bytes" }).download([nameless], dir)

      assert_match(/\Amedia-[0-9a-f]{8}\z/, File.basename(records.first[:path]))
    end
  end
end
