# frozen_string_literal: true

module Xbookmark
  class Keystore
    # Value object mapping a provider name (e.g. "openrouter", "x") to its
    # canonical env-var form and keychain account.
    Provider = Struct.new(:name) do
      def self.parse(arg)
        raw = arg.to_s.strip
        raise Xbookmark::Error, "provider name cannot be empty" if raw.empty?

        normalized = raw.downcase
        unless normalized.match?(self::NAME_PATTERN)
          raise Xbookmark::Error,
            "invalid provider name #{arg.inspect}: must match /\\A[a-z0-9_-]+\\z/"
        end

        # `parse` is the sole constructor: it normalizes, validates, and freezes
        # so the value-object invariant cannot be bypassed (see private `new`).
        new(normalized).freeze
      end

      def account
        name.to_s.downcase
      end

      def env_key
        # Shells (notably bash) reject env-var names containing hyphens, so
        # we translate provider hyphens into underscores: provider "foo-bar"
        # resolves via XBOOKMARK_FOO_BAR_KEY.
        "XBOOKMARK_#{name.to_s.upcase.tr("-", "_")}_KEY"
      end

      def legacy_env_key
        # Backwards-compat for the brainstorm's `XBOOKMARK_X_API_KEY`-style
        # name; the Resolver consults this in its env-fallback branch.
        "XBOOKMARK_#{name.to_s.upcase.tr("-", "_")}_API_KEY"
      end

      def to_s
        name.to_s
      end

      # Force every instance through `parse`, which is the only place the
      # charset/empty/downcase invariant is enforced. Existing callers already
      # use `parse`, so this closes the back door without breaking anyone.
      private_class_method :new
    end

    # The single source of truth for a legal provider-name charset. Defined on
    # the Provider class itself (not the enclosing Keystore scope, where a
    # constant inside the Struct.new block would otherwise land) so AuthConfig
    # and any other caller can reference Provider::NAME_PATTERN without
    # duplicating the regex; `parse` reaches it via `self::NAME_PATTERN`.
    Provider::NAME_PATTERN = /\A[a-z0-9_-]+\z/
  end
end
