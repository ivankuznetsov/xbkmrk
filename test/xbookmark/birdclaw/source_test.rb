# frozen_string_literal: true

require "test_helper"

require "sqlite3"
require "xbookmark/birdclaw/source"

describe Xbookmark::Birdclaw::Source do
  def build_birdclaw_db(path)
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE tweet_collections (
        account_id text, tweet_id text, kind text, collected_at text,
        source text, raw_json text, updated_at text
      );
      CREATE TABLE tweets (
        id text primary key, author_profile_id text, text text, created_at text,
        entities_json text, media_json text, quoted_tweet_id text
      );
      CREATE TABLE profiles (
        id text primary key, handle text, display_name text, avatar_url text
      );
    SQL
    db.execute("INSERT INTO profiles VALUES (?, ?, ?, ?)", ["p1", "alice", "Alice", "https://img.test/alice.jpg"])
    db.execute("INSERT INTO tweets VALUES (?, ?, ?, ?, ?, ?, ?)", [
                 "123", "p1", "A chart", "2025-01-02T03:04:05Z",
                 JSON.generate("urls" => [{ "url" => "https://t.co/x", "expandedUrl" => "https://example.test/post" }]),
                 JSON.generate([{ "type" => "image", "url" => "https://pbs.twimg.com/chart.jpg",
                                  "thumbnailUrl" => "https://pbs.twimg.com/chart-small.jpg", "altText" => "Chart" }]),
                 nil
               ])
    db.execute("INSERT INTO tweet_collections VALUES (?, ?, ?, ?, ?, ?, ?)", [
                 "account", "123", "bookmarks", "2026-08-15T10:11:12Z", "xurl", "{}", "2026-08-15T10:11:12Z"
               ])
    db.execute("INSERT INTO tweets VALUES (?, ?, ?, ?, ?, ?, ?)", [
                 "tweet_001", "p1", "Demo", "2026-01-01T00:00:00Z", "{}", "[]", nil
               ])
    db.execute("INSERT INTO tweet_collections VALUES (?, ?, ?, ?, ?, ?, ?)", [
                 "account", "tweet_001", "bookmarks", "2026-01-01T00:00:00Z", "demo", "{}", "2026-01-01T00:00:00Z"
               ])
  ensure
    db&.close
  end

  it "reads real bookmarks without X and maps Birdclaw image/link fields" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "birdclaw.sqlite")
      build_birdclaw_db(path)

      records = described_class.new(path).records

      assert_equal 1, records.size
      record = records.first
      bookmark = record.bookmark
      assert_equal "123", bookmark.tweet_id
      assert_equal "alice", bookmark.author_handle
      assert_equal "2026-08-15T10:11:12Z", bookmark.bookmarked_at
      assert_equal "https://example.test/post", bookmark.urls.first[:expanded_url]
      assert bookmark.media.first.image?
      assert_equal "https://pbs.twimg.com/chart.jpg", bookmark.media.first.url
      assert_equal "123", record.payload.dig("data", 0, "id")
      refute record.payload.dig("data", 0).key?("xbookmark_bookmarked_at")
    end
  end

  it "fails clearly when the Birdclaw database is absent" do
    error = assert_raises(Xbookmark::ConfigError) { described_class.new("/missing/birdclaw.sqlite").records }

    assert_includes error.message, "Birdclaw database"
  end

  it "maps quoted video variants and tolerates malformed optional JSON" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "birdclaw.sqlite")
      build_birdclaw_db(path)
      db = SQLite3::Database.new(path)
      db.execute("INSERT INTO tweets VALUES (?, ?, ?, ?, ?, ?, ?)", [
                   "124", "p1", "A clip", "2025-01-03T03:04:05Z", "not-json",
                   JSON.generate([{ "type" => "video", "thumbnailUrl" => "https://pbs.twimg.com/clip.jpg",
                                    "variants" => [{ "url" => "https://video.twimg.com/clip.mp4",
                                                     "contentType" => "video/mp4", "bitRate" => 1000 }] }]),
                   "99"
                 ])
      db.execute("INSERT INTO tweet_collections VALUES (?, ?, ?, ?, ?, ?, ?)", [
                   "account", "124", "bookmarks", "2026-08-16T10:11:12Z", "xurl", "{}", "2026-08-16T10:11:12Z"
                 ])
      db.close

      record = described_class.new(path).records.last

      assert_equal "99", record.payload.dig("data", 0, "referenced_tweets", 0, "id")
      assert_empty record.bookmark.urls
      assert_equal "https://video.twimg.com/clip.mp4", record.bookmark.media.first.variants.first["url"]
      assert_equal "video/mp4", record.bookmark.media.first.variants.first["content_type"]
    end
  end

  it "normalizes GIFs and rejects archive-controlled media hosts" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "birdclaw.sqlite")
      build_birdclaw_db(path)
      db = SQLite3::Database.new(path)
      db.execute("UPDATE tweets SET media_json = ? WHERE id = ?", [
                   JSON.generate([{ "type" => "gif", "thumbnailUrl" => "http://127.0.0.1/preview.jpg",
                                    "variants" => [{ "url" => "https://video.twimg.com/loop.mp4",
                                                     "contentType" => "video/mp4" },
                                                   { "url" => "http://[", "contentType" => "video/mp4" }] }]),
                   "123"
                 ])
      db.close

      media = described_class.new(path).records.first.bookmark.media.first

      assert_equal "animated_gif", media.type
      assert_nil media.preview_image_url
      assert_equal "https://video.twimg.com/loop.mp4", media.variants.first["url"]
      assert_nil media.variants.last["url"]
    end
  end

  it "derives a deterministic timestamp when the archive row has none" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "birdclaw.sqlite")
      build_birdclaw_db(path)
      db = SQLite3::Database.new(path)
      db.execute("UPDATE tweets SET created_at = NULL WHERE id = '123'")
      db.execute("UPDATE tweet_collections SET collected_at = NULL WHERE tweet_id = '123'")
      db.close

      timestamp = described_class.new(path).records.first.bookmark.bookmarked_at

      assert_equal "2010-11-04T01:42:54.657Z", timestamp
    end
  end

  it "wraps unreadable SQLite schemas as configuration errors" do
    Tempfile.create(["empty-birdclaw", ".sqlite"]) do |file|
      error = assert_raises(Xbookmark::ConfigError) { described_class.new(file.path).records }
      assert_includes error.message, "Cannot read Birdclaw database"
    end
  end
end
