# frozen_string_literal: true

require "base64"
require "faraday"
require "json"
require "json-schema"
require_relative "defaults"

module Xbookmark
  module Enrich
    # OpenRouter-backed enrichment client. Text-only prompts use DeepSeek's
    # inexpensive V4 Flash alias; prompts with image files use Qwen 3.8 27B so
    # the same orchestration contract stays multimodal without a local agent.
    class OpenRouter
      ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
      DEFAULT_TEXT_MODEL = Defaults::TEXT_MODEL
      DEFAULT_VISION_MODEL = Defaults::VISION_MODEL
      DEFAULT_IMAGE_DETAIL = Defaults::IMAGE_DETAIL
      DEFAULT_TIMEOUT = 300
      VALID_IMAGE_DETAILS = %w[auto low high].freeze
      PERMANENT_HTTP_STATUSES = [400, 404, 405, 422].freeze

      def self.from_config(config, text_model: nil)
        new(
          api_key: config.openrouter_api_key,
          text_model: text_model || config.openrouter_text_model,
          vision_model: config.openrouter_vision_model,
          image_detail: config.openrouter_image_detail
        )
      end

      def initialize(api_key:, text_model: DEFAULT_TEXT_MODEL, vision_model: DEFAULT_VISION_MODEL,
                     image_detail: DEFAULT_IMAGE_DETAIL, connection: nil)
        unless VALID_IMAGE_DETAILS.include?(image_detail.to_s)
          raise Xbookmark::ConfigError, "OPENROUTER_IMAGE_DETAIL must be one of: #{VALID_IMAGE_DETAILS.join(', ')}"
        end

        @api_key = api_key
        @text_model = text_model
        @vision_model = vision_model
        @image_detail = image_detail.to_s
        @connection = connection || Faraday.new
      end

      def run(prompt:, images: [], json_schema: nil, timeout: DEFAULT_TIMEOUT, extra_argv: [])
        raise ArgumentError, "extra_argv is not supported by the OpenRouter client" unless Array(extra_argv).empty?

        response = post(payload(prompt: prompt, images: images, json_schema: json_schema), timeout: timeout)
        handle_error!(response) unless response.success?
        content = extract_content(response.body)
        return content unless json_schema

        parsed = JSON.parse(content)
        validate_schema!(json_schema, parsed)
        parsed
      rescue JSON::ParserError => e
        raise Xbookmark::EnrichmentError, "OpenRouter response was not valid JSON: #{e.message}"
      rescue Faraday::Error => e
        raise Xbookmark::EnrichmentError, "OpenRouter request failed: #{e.class}: #{e.message}"
      end

      private

      def post(body, timeout:)
        if @api_key.to_s.strip.empty?
          raise Xbookmark::EnrichmentError, "OPENROUTER_API_KEY is required for bookmark enrichment"
        end

        @connection.post(ENDPOINT) do |request|
          request.headers["Authorization"] = "Bearer #{@api_key}"
          request.headers["Content-Type"] = "application/json"
          request.headers["HTTP-Referer"] = "https://github.com/ivankuznetsov/xbkmrk"
          request.headers["X-Title"] = "xbkmrk"
          request.options.timeout = timeout
          request.options.open_timeout = [timeout.to_f, 30].min
          request.body = JSON.generate(body)
        end
      end

      def payload(prompt:, images:, json_schema:)
        image_paths = Array(images)
        body = {
          "model" => image_paths.empty? ? @text_model : @vision_model,
          "messages" => [{ "role" => "user", "content" => message_content(prompt, image_paths) }],
          "temperature" => 0.1
        }
        if json_schema
          body["response_format"] = {
            "type" => "json_schema",
            "json_schema" => { "name" => "xbookmark_output", "strict" => false, "schema" => json_schema }
          }
        end
        body
      end

      def message_content(prompt, image_paths)
        return prompt.to_s if image_paths.empty?

        [{ "type" => "text", "text" => prompt.to_s }] + image_paths.map do |path|
          {
            "type" => "image_url",
            "image_url" => {
              "url" => "data:#{mime_type(path)};base64,#{Base64.strict_encode64(File.binread(path))}",
              "detail" => @image_detail
            }
          }
        rescue Errno::ENOENT, Errno::EACCES => e
          raise Xbookmark::PermanentError, "cannot read enrichment image #{File.basename(path.to_s)}: #{e.message}"
        end
      end

      def mime_type(path)
        case File.extname(path.to_s).downcase
        when ".png" then "image/png"
        when ".webp" then "image/webp"
        when ".gif" then "image/gif"
        else "image/jpeg"
        end
      end

      def extract_content(raw)
        data = JSON.parse(raw)
        content = data.dig("choices", 0, "message", "content")
        if content.is_a?(Array)
          content = content.filter_map { |part| part["text"] if part.is_a?(Hash) }.join
        end
        raise Xbookmark::EnrichmentError, "OpenRouter returned an empty model response" if content.to_s.strip.empty?

        content.to_s
      end

      def validate_schema!(schema, parsed)
        errors = JSON::Validator.fully_validate(schema, parsed)
        return if errors.empty?

        raise Xbookmark::PermanentError, "OpenRouter output failed schema validation: #{errors.join('; ')}"
      end

      def handle_error!(response)
        message = provider_error_message(response.body)
        if response.status.to_i == 429
          reset = response.headers["x-ratelimit-reset"]
          raise Xbookmark::RateLimited.new("OpenRouter rate limited the request: #{message}", reset_at: reset)
        end
        status = response.status.to_i
        if status >= 500 || !PERMANENT_HTTP_STATUSES.include?(status)
          raise Xbookmark::EnrichmentError, "OpenRouter returned HTTP #{response.status}: #{message}"
        end

        raise Xbookmark::PermanentError, "OpenRouter rejected the request (HTTP #{response.status}): #{message}"
      end

      def provider_error_message(raw)
        parsed = JSON.parse(raw)
        (parsed.dig("error", "message") || "request failed").to_s[0, 300]
      rescue JSON::ParserError
        "request failed"
      end
    end
  end
end
