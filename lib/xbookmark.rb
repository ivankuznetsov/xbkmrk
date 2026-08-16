# frozen_string_literal: true

module Xbookmark
  class Error < StandardError; end
  class ConfigError < Error; end
  class AuthError < Error; end
  class TransientAuthError < AuthError; end
  class RateLimited < Error
    attr_reader :reset_at

    def initialize(message, reset_at: nil)
      super(message)
      @reset_at = reset_at
    end
  end

  class TransientError < Error; end
  class PermanentError < Error; end
  class SourceUnavailable < Error; end
  class MediaError < TransientError; end
  class WhisperUnavailable < TransientError; end
  class EnrichmentError < TransientError; end
  CodexError = EnrichmentError # compatibility for callers of the former local-Codex adapter
  class UnsupportedPlatform < Error; end
end

require_relative "xbookmark/version"
require_relative "xbookmark/paths"
require_relative "xbookmark/config"
