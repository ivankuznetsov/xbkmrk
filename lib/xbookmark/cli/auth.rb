# frozen_string_literal: true

require "thor"
require "io/console"
require "time"

module Xbookmark
  class CLI
    class Auth < Thor
      class_option :wiki, type: :string
      class_option :vault, type: :string
      class_option :verbose, type: :boolean, default: false

      desc "login [PROVIDER]", "OAuth login to X (no arg) or store a static key for PROVIDER"
      long_desc <<~LONG
        With no argument, runs the OAuth 2.0 PKCE flow against X and stores
        the resulting tokens in the keystore (existing behaviour).

        With a PROVIDER argument (e.g. `openrouter`), prompts for the API
        key on stdin without echoing it, writes the value into the host
        keystore (Keychain on macOS, libsecret on Linux), and records the
        routing in ~/.config/xbookmark/auth.toml.  The value is never
        accepted on argv or via a flag, so it cannot land in shell history.
      LONG
      def login(provider = nil)
        if provider.nil?
          require_relative "../config"
          require_relative "../x/auth"
          config = Xbookmark::Config.load(wiki_override: options[:wiki], vault_override: options[:vault], verbose: options[:verbose])
          result = Xbookmark::X::Auth.new(config).login
          warn "Logged in. Tokens written to #{result.env_file}." if result
        else
          provider_login(provider)
        end
      rescue Xbookmark::TransientAuthError => e
        warn "[xbookmark] #{redact_secret_like_values(e.message)}"
        warn "X token login is temporarily unavailable. Retry auth login later."
        exit 2
      rescue Xbookmark::AuthError => e
        warn "[xbookmark] #{redact_secret_like_values(e.message)}"
        warn "Run: xbookmark auth login"
        exit 1
      end

      desc "bind PROVIDER OP_REF", "Bind PROVIDER to a 1Password reference (op://...)"
      def bind(provider, op_ref)
        require_relative "../keystore/provider"
        require_relative "../keystore/auth_config"
        require_relative "../keystore/one_password"

        prov = Xbookmark::Keystore::Provider.parse(provider)
        unless op_ref.to_s.start_with?("op://")
          warn "Bad 1Password reference: must start with op:// (got #{op_ref.inspect})"
          exit 1
        end

        cfg = Xbookmark::Keystore::AuthConfig.new
        cfg.bind_one_password(prov, op_ref)

        # Optional smoke-check: if `op` is installed, validate the reference
        # immediately so the user finds out at bind-time, not first sync.
        # The resolved value is discarded.
        if Xbookmark::Keystore::OnePassword.available?
          begin
            Xbookmark::Keystore::OnePassword.new.read(op_ref)
          rescue Xbookmark::Error => e
            warn "Warning: bound #{prov.name} but op read failed: #{e.message}"
          end
        end

        puts "Bound #{prov.name} to #{op_ref}."
      end

      desc "list", "List configured provider credentials (never prints values)"
      def list
        require_relative "../keystore/auth_config"

        cfg = Xbookmark::Keystore::AuthConfig.new
        rows = cfg.entries.map do |name, entry|
          [name, entry[:backend], entry[:ref].to_s]
        end

        env_rows = ENV.keys.grep(/\AXBOOKMARK_(.+)_KEY\z/).map do |env_key|
          name = env_key.sub(/\AXBOOKMARK_/, "").sub(/_KEY\z/, "").downcase
          next nil if rows.any? { |r| r[0] == name }
          [name, "env", env_key]
        end.compact

        all = rows + env_rows
        if all.empty?
          puts "No providers configured."
          return
        end

        width_name = all.map { |r| r[0].length }.max
        width_backend = all.map { |r| r[1].length }.max
        all.sort_by { |r| r[0] }.each do |name, backend, extra|
          printf("%-#{width_name}s  %-#{width_backend}s  %s\n", name, backend, extra)
        end
      end

      desc "show PROVIDER", "Resolve and print PROVIDER's credential (diagnostic; for scripts/CI)"
      def show(provider)
        require_relative "../keystore/provider"
        require_relative "../keystore/resolver"

        prov = Xbookmark::Keystore::Provider.parse(provider)
        value = Xbookmark::Keystore::Resolver.new.resolve(prov)
        puts value
      rescue Xbookmark::Error => e
        warn e.message
        exit 1
      end

      desc "rm PROVIDER", "Remove PROVIDER from auth.toml (and its keychain entry, if any)"
      def rm(provider)
        require_relative "../keystore/provider"
        require_relative "../keystore/auth_config"

        prov = Xbookmark::Keystore::Provider.parse(provider)
        cfg = Xbookmark::Keystore::AuthConfig.new
        entry = cfg.lookup(prov)

        unless entry
          puts "#{prov.name} was not configured."
          return
        end

        if entry[:backend] == "keychain"
          backend = pick_keychain_backend
          backend.delete(prov.account) if backend
        end

        cfg.remove(prov)
        puts "Removed #{prov.name}."
      end

      desc "status", "Print the current X auth status"
      def status
        require_relative "../config"
        config = Xbookmark::Config.load(wiki_override: options[:wiki], vault_override: options[:vault], verbose: options[:verbose])
        unless config.x_access_token && !config.x_access_token.empty?
          puts "Not logged in. Run: xbookmark auth login"
          exit 1
        end

        expires_at = config.x_token_expires_at
        if expires_at && expires_at <= Time.now.to_i
          puts "Access token expired at: #{format_timestamp(expires_at)}"
          if config.x_refresh_token && !config.x_refresh_token.empty?
            puts "Refresh token present. Run: xbookmark auth refresh"
          else
            puts "No refresh token. Run: xbookmark auth login"
          end
          exit 1
        end

        puts "Logged in. Token expires at: #{expires_at ? format_timestamp(expires_at) : "unknown"}"
      end

      desc "refresh", "Refresh the saved X OAuth token"
      def refresh
        require_relative "../config"
        require_relative "../x/auth"
        config = Xbookmark::Config.load(wiki_override: options[:wiki], vault_override: options[:vault], verbose: options[:verbose])
        result = Xbookmark::X::Auth.new(config).refresh!
        warn "Refreshed. Tokens written to #{result.env_file}."
        warn "Token expires at: #{format_timestamp(result.expires_at.to_i)}"
      rescue Xbookmark::TransientAuthError => e
        warn "[xbookmark] #{redact_secret_like_values(e.message)}"
        warn "X token refresh is temporarily unavailable. Retry later."
        exit 2
      rescue Xbookmark::AuthError => e
        warn "[xbookmark] #{redact_secret_like_values(e.message)}"
        warn "Run: xbookmark auth login"
        exit 1
      end

      private

      SECRET_LIKE_VALUE = /[A-Za-z0-9_\-.~+\/=]{32,}/
      SECRET_FIELD = /
        \b(access_token|refresh_token|client_secret|authorization|token)
        (["']?\s*[:=]\s*["']?)
        [^"',}\s]+
      /ix

      def redact_secret_like_values(message)
        message.to_s
               .gsub(SECRET_FIELD, "\\1\\2[REDACTED]")
               .gsub(SECRET_LIKE_VALUE, "[REDACTED]")
      end

      def format_timestamp(value)
        "#{value} (#{Time.at(value.to_i).utc.iso8601})"
      end

      private

      def provider_login(provider_arg)
        require_relative "../keystore/provider"
        require_relative "../keystore/auth_config"
        require_relative "../keystore/keychain"
        require_relative "../keystore/libsecret"
        require_relative "../paths"

        prov = Xbookmark::Keystore::Provider.parse(provider_arg)
        backend = pick_keychain_backend
        unless backend
          warn "No platform keychain available. " \
            "Install libsecret (`secret-tool`) on Linux, or use `xbookmark auth bind #{prov.name} op://...`."
          exit 1
        end

        value = read_secret_from_stdin("Enter #{prov.name} key (input hidden): ")
        if value.to_s.empty?
          warn "No value entered; nothing stored."
          exit 1
        end

        backend.set(prov.account, value)
        Xbookmark::Keystore::AuthConfig.new.bind_keychain(prov)
        puts "Stored #{prov.name} in #{backend.name}."
      end

      def pick_keychain_backend
        if Xbookmark::Paths.macos?
          Xbookmark::Keystore::Keychain.new
        elsif Xbookmark::Keystore::Libsecret.available?
          Xbookmark::Keystore::Libsecret.new
        end
      end

      def read_secret_from_stdin(prompt)
        $stderr.write(prompt)
        $stderr.flush
        if $stdin.tty? && $stdin.respond_to?(:noecho)
          value = $stdin.noecho(&:gets)
          $stderr.puts
        else
          value = $stdin.gets
        end
        value.to_s.chomp
      end
    end
  end
end
