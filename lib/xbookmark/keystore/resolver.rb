# frozen_string_literal: true

require_relative "../keystore"
require_relative "../paths"
require_relative "provider"
require_relative "auth_config"
require_relative "one_password"
require_relative "keychain"
require_relative "libsecret"

module Xbookmark
  class Keystore
    # Runtime priority chain for resolving a provider's API key.
    #
    # Order:
    #   1. CI / `XBOOKMARK_KEYS_FROM_ENV=1`        -> env[provider.env_key]
    #   2. auth.toml routing:
    #        backend = "1password" -> op read <ref>
    #        backend = "keychain"  -> platform keychain (libsecret on Linux,
    #                                 Keychain on macOS)
    #   3. env[provider.env_key], with the legacy
    #      `XBOOKMARK_<PROVIDER>_API_KEY` form also recognised (with a
    #      one-time deprecation warning)
    #   4. raise Xbookmark::Error with actionable subcommand hints
    class Resolver
      # Process-global memo of which legacy env vars we've already warned about,
      # so the deprecation notice prints at most once per process. Intentionally
      # shared across Resolver instances — this is "warn once per CLI run", not
      # per-instance state. A long-running host (e.g. the test runner) should
      # `.clear` it between runs; tests do exactly that in their `before` block.
      LEGACY_WARNED = {}
      private_constant :LEGACY_WARNED

      def initialize(config: AuthConfig.new, env: ENV, platform: Xbookmark::Paths,
                     keychain: nil, libsecret: nil, one_password: nil, warn_io: $stderr)
        @config = config
        @env = env
        @platform = platform
        @keychain = keychain
        @libsecret = libsecret
        @one_password = one_password
        @warn_io = warn_io
      end

      def resolve(provider)
        prov = provider.is_a?(Provider) ? provider : Provider.parse(provider)

        if ci_env?
          value = @env[prov.env_key] || legacy_env_value(prov)
          return value if non_empty?(value)
          raise missing_error(prov, source: "env")
        end

        entry = @config.lookup(prov)
        if entry
          value = resolve_from_entry(prov, entry)
          return value if non_empty?(value)
          raise Xbookmark::Error,
            "auth.toml routes #{prov.name} to #{entry[:backend]} but the backend returned no value. " \
              "Re-run `xbookmark auth login #{prov.name}` or update the binding."
        end

        env_value = @env[prov.env_key] || legacy_env_value(prov)
        return env_value if non_empty?(env_value)

        raise missing_error(prov)
      end

      private

      def ci_env?
        @env["CI"].to_s == "true" || @env["XBOOKMARK_KEYS_FROM_ENV"].to_s == "1"
      end

      def resolve_from_entry(provider, entry)
        case entry[:backend]
        when "1password"
          one_password_backend.read(entry[:ref])
        when "keychain"
          keychain_get(provider)
        else
          raise Xbookmark::Error,
            "unknown auth.toml backend #{entry[:backend].inspect} for #{provider.name}"
        end
      end

      # Read from the platform keychain, translating a missing CLI into an
      # actionable Xbookmark::Error rather than letting a raw Errno::ENOENT
      # (from the `secret-tool` shell-out) escape to `auth show`/sync callers.
      # An injected @keychain (tests) skips the availability probe.
      def keychain_get(provider)
        if !@keychain && !@platform.macos? && !Libsecret.available?
          raise Xbookmark::Error, keychain_unavailable_message(provider)
        end
        keychain_backend.get(provider.account)
      rescue Errno::ENOENT
        raise Xbookmark::Error, keychain_unavailable_message(provider)
      end

      def keychain_unavailable_message(provider)
        "auth.toml routes #{provider.name} to the platform keychain, but it is " \
          "unavailable. Install libsecret (`secret-tool`) on Linux, then re-run " \
          "`xbookmark auth login #{provider.name}`."
      end

      def keychain_backend
        return @keychain if @keychain
        @keychain = @platform.macos? ? Keychain.new : Libsecret.new
      end

      def one_password_backend
        @one_password ||= OnePassword.new
      end

      def legacy_env_value(provider)
        legacy_key = provider.legacy_env_key
        return nil if legacy_key == provider.env_key
        value = @env[legacy_key]
        return nil unless non_empty?(value)
        warn_legacy_once(provider, legacy_key)
        value
      end

      def warn_legacy_once(provider, legacy_key)
        return if LEGACY_WARNED[legacy_key]
        LEGACY_WARNED[legacy_key] = true
        @warn_io.puts(
          "[xbookmark] #{legacy_key} is deprecated; use #{provider.env_key} instead."
        )
      end

      def non_empty?(value)
        !value.nil? && !value.to_s.strip.empty?
      end

      def missing_error(provider, source: nil)
        msg = +"No credential configured for #{provider.name}."
        if source == "env"
          msg << " CI/XBOOKMARK_KEYS_FROM_ENV is set; export #{provider.env_key} in the environment."
        else
          msg << " Run 'xbookmark auth login #{provider.name}' "
          msg << "or 'xbookmark auth bind #{provider.name} op://...'."
        end
        Xbookmark::Error.new(msg)
      end
    end
  end
end
