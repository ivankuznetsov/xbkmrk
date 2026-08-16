# frozen_string_literal: true

require "test_helper"

require "xbookmark/enrich/open_router"

describe Xbookmark::Enrich::OpenRouter do
  let(:endpoint) { "https://openrouter.ai/api/v1/chat/completions" }
  let(:schema) do
    {
      "type" => "object",
      "required" => %w[summary],
      "properties" => { "summary" => { "type" => "string" } }
    }
  end

  it "routes text-only enrichment to the latest DeepSeek V4 Flash model" do
    stub_request(:post, endpoint).to_return(
      status: 200,
      body: JSON.generate("choices" => [{ "message" => { "content" => '{"summary":"fast"}' } }]),
      headers: { "Content-Type" => "application/json" }
    )

    result = described_class.new(api_key: "router-key").run(prompt: "Summarize", json_schema: schema)

    assert_equal({ "summary" => "fast" }, result)
    assert_requested(:post, endpoint) do |raw|
      body = JSON.parse(raw.body)
      body["model"] == described_class::DEFAULT_TEXT_MODEL &&
        body.dig("messages", 0, "content") == "Summarize" &&
        body.dig("response_format", "type") == "json_schema"
    end
  end

  it "routes image enrichment to Qwen 3.8 27B with low-detail inline images" do
    stub_request(:post, endpoint).to_return(
      status: 200,
      body: JSON.generate("choices" => [{ "message" => { "content" => '{"summary":"diagram"}' } }]),
      headers: { "Content-Type" => "application/json" }
    )

    Tempfile.create(["bookmark", ".png"]) do |image|
      image.binmode
      image.write("png-bytes")
      image.flush

      result = described_class.new(api_key: "router-key").run(
        prompt: "Read the image", images: [image.path], json_schema: schema
      )

      assert_equal({ "summary" => "diagram" }, result)
    end

    assert_requested(:post, endpoint) do |raw|
      body = JSON.parse(raw.body)
      content = body.dig("messages", 0, "content")
      body["model"] == described_class::DEFAULT_VISION_MODEL &&
        content.first == { "type" => "text", "text" => "Read the image" } &&
        content.last.dig("image_url", "url").start_with?("data:image/png;base64,") &&
        content.last.dig("image_url", "detail") == "low"
    end
  end

  it "raises a retryable error for provider failures without leaking the key" do
    stub_request(:post, endpoint).to_return(status: 503, body: '{"error":{"message":"overloaded"}}')

    error = assert_raises(Xbookmark::EnrichmentError) do
      described_class.new(api_key: "never-print-me").run(prompt: "x", json_schema: schema)
    end

    assert_includes error.message, "503"
    refute_includes error.message, "never-print-me"
  end

  it "defers a missing key to a retryable request error" do
    client = described_class.new(api_key: nil)

    error = assert_raises(Xbookmark::EnrichmentError) { client.run(prompt: "x") }

    assert_includes error.message, "OPENROUTER_API_KEY"
  end

  it "treats account-level authorization and credit failures as retryable" do
    stub_request(:post, endpoint).to_return(status: 402, body: '{"error":{"message":"credits exhausted"}}')

    assert_raises(Xbookmark::EnrichmentError) do
      described_class.new(api_key: "router-key").run(prompt: "x")
    end
  end

  it "maps rate limits onto the pipeline's rate-limit error" do
    stub_request(:post, endpoint).to_return(
      status: 429,
      body: '{"error":{"message":"slow down"}}',
      headers: { "X-RateLimit-Reset" => "1786900000" }
    )

    assert_raises(Xbookmark::RateLimited) do
      described_class.new(api_key: "router-key").run(prompt: "x", json_schema: schema)
    end
  end

  it "rejects responses that do not satisfy the requested schema" do
    stub_request(:post, endpoint).to_return(
      status: 200,
      body: JSON.generate("choices" => [{ "message" => { "content" => "{}" } }]),
      headers: { "Content-Type" => "application/json" }
    )

    assert_raises(Xbookmark::PermanentError) do
      described_class.new(api_key: "router-key").run(prompt: "x", json_schema: schema)
    end
  end

  it "validates configuration and local image paths" do
    assert_raises(Xbookmark::ConfigError) do
      described_class.new(api_key: "router-key", image_detail: "huge")
    end

    assert_raises(Xbookmark::PermanentError) do
      described_class.new(api_key: "router-key").run(prompt: "x", images: ["/missing/image.png"])
    end
  end

  it "maps malformed and failed provider responses" do
    stub_request(:post, endpoint).to_return(status: 200, body: "not-json")
    assert_raises(Xbookmark::EnrichmentError) do
      described_class.new(api_key: "router-key").run(prompt: "x", json_schema: schema)
    end

    stub_request(:post, endpoint).to_raise(Faraday::ConnectionFailed.new("offline"))
    assert_raises(Xbookmark::EnrichmentError) do
      described_class.new(api_key: "router-key").run(prompt: "x")
    end

    stub_request(:post, endpoint).to_return(status: 400, body: "not-json")
    assert_raises(Xbookmark::PermanentError) do
      described_class.new(api_key: "router-key").run(prompt: "x")
    end
  end

  it "accepts array content and labels supported image mime types" do
    stub_request(:post, endpoint).to_return(
      status: 200,
      body: JSON.generate("choices" => [{ "message" => { "content" => [{ "text" => "ok" }, { "type" => "ignored" }] } }])
    )

    client = described_class.new(api_key: "router-key")
    assert_equal "ok", client.run(prompt: "x")
    assert_equal "image/webp", client.send(:mime_type, "image.webp")
    assert_equal "image/gif", client.send(:mime_type, "image.gif")
    assert_equal "image/jpeg", client.send(:mime_type, "image.jpg")
  end
end
