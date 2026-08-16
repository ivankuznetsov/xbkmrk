# frozen_string_literal: true

require "test_helper"

require "xbookmark/enrich/codex" # legacy adapter used only as an in-memory test double
require "xbookmark/enrich/orchestrator"
require "xbookmark/x/bookmark"

describe Xbookmark::Enrich::Orchestrator do
  let(:bookmark) do
    Xbookmark::X::Bookmark.new(
      tweet_id: "1",
      author_handle: "alice",
      author_name: "Alice",
      author_id: "u1",
      text: "ozempic dose data",
      media: [],
      urls: [{ url: "https://t.co/x", expanded_url: "https://example.com/a", display_url: "example.com/a" }],
      bookmarked_at: "2026-01-01T00:00:00Z",
      created_at: "2026-01-01T00:00:00Z",
      conversation_id: "1"
    )
  end

  let(:link_fetcher) do
    mock("link fetcher").tap do |lf|
      lf.stubs(:fetch).returns(
        { url: "https://example.com/a", final_url: "https://example.com/a",
          title: "Article", byline: nil, text: "body of article",
          fetched_at: "2026-01-01T00:00:00Z" }
      )
    end
  end

  it "happy path: fetches external links directly and final returns full result" do
    fake = FakeCodex.new
    fake.push({
      "summary" => "Talks about ozempic dosing.",
      "tags" => ["health"],
      "concepts" => [{ "label" => "ozempic", "kind" => "entity" }, { "label" => "novo-nordisk", "kind" => "organization" }],
      "links" => [{ "url" => "https://example.com/a", "title" => "Article", "summary" => "ok" }],
      "transcript_summaries" => { "video.mp4" => "A short transcript summary." },
      "formatted_transcripts" => { "video.mp4" => "**Speaker 1:** Hello." }
    })

    codex = Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake)
    orch = described_class.new(codex: codex, link_fetcher: link_fetcher)
    result = orch.enrich(bookmark, transcripts: { "video.mp4" => "hello" })
    assert_equal "Talks about ozempic dosing.", result.summary
    # No title in the payload → defaults to the summary's first clause.
    assert_equal "Talks about ozempic dosing", result.title
    assert_equal ["health"], result.tags
    assert_equal ["ozempic", "novo-nordisk"], result.concepts.map { |concept| concept["label"] }
    assert_equal({ "video.mp4" => "A short transcript summary." }, result.transcript_summaries)
    assert_equal({ "video.mp4" => "**Speaker 1:** Hello." }, result.formatted_transcripts)
    refute result.partial?
    # Fetched link blobs are returned so the renderer can build the
    # "Linked Articles" section without re-fetching.
    assert_equal 1, result.link_blobs.size
    assert_equal "https://example.com/a", result.link_blobs.first[:url]
    assert_equal 1, fake.calls.size
  end

  it "uses the model title when present and sanitizes wikilink metacharacters" do
    fake = FakeCodex.new
    fake.push({
      "title" => "Ozempic dosing]] | guide",
      "summary" => "Talks about dosing.",
      "tags" => ["health"],
      "concepts" => [{ "label" => "ozempic", "kind" => "entity" }]
    })
    codex = Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake)

    result = described_class.new(codex: codex, link_fetcher: link_fetcher).enrich(bookmark)

    assert_equal "Ozempic dosing guide", result.title
  end

  it "marks result partial when retry still has empty required fields" do
    fake = FakeCodex.new
    fake.push({ "summary" => "x", "tags" => [], "concepts" => [] })
    fake.push({ "summary" => "x", "tags" => [], "concepts" => [] })

    codex = Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake)
    orch = described_class.new(codex: codex, link_fetcher: link_fetcher)
    result = orch.enrich(bookmark)
    assert result.partial?
  end

  it "successful retry overwrites partial result" do
    fake = FakeCodex.new
    fake.push({ "summary" => "x", "tags" => [], "concepts" => [] })
    fake.push({ "summary" => "x", "tags" => ["a"], "concepts" => [{ "label" => "e", "kind" => "idea" }] })

    codex = Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake)
    orch = described_class.new(codex: codex, link_fetcher: link_fetcher)
    result = orch.enrich(bookmark)
    refute result.partial?
    assert_equal ["a"], result.tags
    assert_equal ["e"], result.concepts.map { |concept| concept["label"] }
  end

  it "falls back to text-only enrichment when image codex fails transiently" do
    fake = FakeCodex.new
    fake.push(Xbookmark::CodexError.new("empty image response"))
    fake.push({ "summary" => "x", "tags" => ["t"], "concepts" => [{ "label" => "topic", "kind" => "idea" }] })

    result = described_class.new(codex: Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake), link_fetcher: link_fetcher)
      .enrich(bookmark, image_paths: ["/tmp/a.jpg"])

    assert result.partial?
    assert_equal ["t"], result.tags
    assert_includes fake.calls.first, "--image"
    refute_includes fake.calls.last, "--image"
  end

  it "falls back to text-only enrichment when image codex returns only wrapper events" do
    fake = FakeCodex.new
    fake.push({ "type" => "turn.started" }.to_json)
    fake.push({ "summary" => "x", "tags" => ["t"], "concepts" => [{ "label" => "topic", "kind" => "idea" }] })

    result = described_class.new(codex: Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake), link_fetcher: link_fetcher)
      .enrich(bookmark, image_paths: ["/tmp/a.jpg"])

    assert result.partial?
    assert_equal ["t"], result.tags
    assert_includes fake.calls.first, "--image"
    refute_includes fake.calls.last, "--image"
  end

  it "propagates image fallback failure when text-only codex also fails" do
    fake = FakeCodex.new
    fake.push(Xbookmark::CodexError.new("empty image response"))
    fake.push(Xbookmark::CodexError.new("empty text response"))

    assert_raises(Xbookmark::CodexError) do
      described_class.new(codex: Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake), link_fetcher: link_fetcher)
        .enrich(bookmark, image_paths: ["/tmp/a.jpg"])
    end
    assert_equal 2, fake.calls.size
    assert_includes fake.calls.first, "--image"
    refute_includes fake.calls.last, "--image"
  end

  it "propagates codex failures when no image fallback is available" do
    fake = FakeCodex.new.push(Xbookmark::CodexError.new("empty response"))

    assert_raises(Xbookmark::CodexError) do
      described_class.new(codex: Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake), link_fetcher: link_fetcher)
        .enrich(bookmark)
    end
  end

  it "does not fetch X media/status URLs as article describe" do
    bookmark.urls = [{ url: "https://t.co/v", expanded_url: "https://x.com/alice/status/1/video/1" }]
    fake = FakeCodex.new.push({
      "summary" => "x",
      "tags" => ["t"],
      "concepts" => [{ "label" => "topic", "kind" => "idea" }]
    })

    codex = Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake)
    link_fetcher.expects(:fetch).never
    orch = described_class.new(codex: codex, link_fetcher: link_fetcher)
    result = orch.enrich(bookmark)

    assert_empty result.link_blobs
  end

  it "fetches at most three unique external article URLs from string and hash inputs" do
    bookmark.urls = [
      "https://example.com/one",
      { "expanded_url" => "https://example.com/two" },
      { expanded_url: "https://example.com/three" },
      { url: "https://example.com/four" },
      { expanded_url: "not a url" },
      { expanded_url: "https://t.co/skip" },
      { expanded_url: "https://example.com/one" }
    ]
    fake = FakeCodex.new.push({
      "summary" => "x",
      "tags" => ["t"],
      "concepts" => [{ "label" => "topic", "kind" => "idea" }]
    })
    fetched = []
    link_fetcher.stubs(:fetch).with do |url|
      fetched << url
      true
    end.returns({ url: "fetched", final_url: "fetched", title: "fetched", byline: nil, text: "body", fetched_at: "now" })

    described_class.new(codex: Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake), link_fetcher: link_fetcher)
      .enrich(bookmark)

    assert_equal %w[
      https://example.com/one
      https://example.com/two
      https://example.com/three
    ], fetched
  end

  it "falls back to the first partial result when retry raises" do
    fake = FakeCodex.new
    fake.push({ "summary" => "x", "tags" => [], "concepts" => [] })
    fake.push(Xbookmark::PermanentError.new("bad retry"))

    result = described_class.new(codex: Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake), link_fetcher: link_fetcher)
      .enrich(bookmark)

    assert result.partial?
    assert_equal [], result.tags
    assert_equal [], result.concepts
  end

  it "includes quoted tweet text in retry prompts" do
    bookmark.quoted_tweet = { "text" => "quoted describe" }
    fake = FakeCodex.new
    fake.push({ "summary" => "x", "tags" => [], "concepts" => [] })
    fake.push({ "summary" => "x", "tags" => ["tag"], "concepts" => [{ "label" => "entity", "kind" => "idea" }] })

    described_class.new(codex: Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake), link_fetcher: link_fetcher)
      .enrich(bookmark)

    assert_includes fake.stdin_inputs.last, "quoted describe"
  end

  it "includes transcript snippets in retry prompts" do
    fake = FakeCodex.new
    fake.push({ "summary" => "x", "tags" => [], "concepts" => [] })
    fake.push({ "summary" => "x", "tags" => ["tag"], "concepts" => [{ "label" => "entity", "kind" => "idea" }] })

    described_class.new(codex: Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake), link_fetcher: link_fetcher)
      .enrich(bookmark, transcripts: { "video.mp4" => "spoken words" })

    assert_includes fake.stdin_inputs.last, "[video.mp4]\nspoken words"
  end

  it "summarizes aux pages through codex templates" do
    fake = FakeCodex.new
    fake.push({ "summary" => "Topic summary" })
    fake.push({ "summary" => "Author summary" })
    orch = described_class.new(codex: Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake), link_fetcher: link_fetcher)

    assert_equal "Topic summary", orch.summarize_topic(slug: "ozempic", snippets: %w[a b])
    assert_equal "Author summary", orch.summarize_author(handle: "alice", snippets: ["first"])
    assert_includes fake.stdin_inputs.first, "ozempic"
    assert_includes fake.stdin_inputs.last, "alice"
  end

  it "runs the vision prompt with image timeout when asked directly" do
    fake = FakeCodex.new.push({ "captions" => { "a.jpg" => "cap" }, "ocr" => {} })
    codex = Xbookmark::Enrich::Codex.new(bin: "codex", runner: fake)
    orch = described_class.new(codex: codex, link_fetcher: link_fetcher)

    result = orch.send(:vision_call, ["/tmp/a.jpg"])

    assert_equal({ "a.jpg" => "cap" }, result["captions"])
    assert_includes fake.calls.first, "--image"
    assert_includes fake.calls.first, "/tmp/a.jpg"
  end
end
