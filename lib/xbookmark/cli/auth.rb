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
        routing in ~/.config/xbookmark/auth.toml.  The API key value is
        never accepted on argv or via a flag, so it cannot land in shell
        history (the `bind` subcommand, by contrast, does take an `op://`
        reference on argv — that is a pointer, not the secret itself).
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
        require_relative "../keystore/keychain"
        require_relative "../keystore/libsecret"

        prov = parse_provider(provider)
        unless op_ref.to_s.start_with?("op://")
          warn "Bad 1Password reference: must start with op:// (got #{op_ref.inspect})"
          exit 1
        end

        # Smoke-check *before* persisting: if `op` is installed, validate the
        # reference now so a bad ref fails fast instead of being written and
        # only surfacing at resolve time. The resolved value is discarded.
        # "Not signed in" and a timeout are warn-and-continue cases (we cannot
        # verify, but the ref may well be fine — a slow vault is not a bad ref);
        # any other failure means the ref is broken.
        if Xbookmark::Keystore::OnePassword.available?
          begin
            Xbookmark::Keystore::OnePassword.new.read(op_ref)
          rescue Xbookmark::Keystore::OnePassword::NotSignedInError,
                 Xbookmark::Keystore::OnePassword::TimeoutError => e
            warn "Warning: binding #{prov.name} without verification (#{e.message})"
          rescue Xbookmark::Error, SystemCallError => e
            warn "Refusing to bind #{prov.name}: op read failed: #{e.message}"
            exit 1
          end
        end

        cfg = load_auth_config

        # If the provider currently routes to the platform keychain, delete that
        # stored secret *before* persisting the 1Password binding. Otherwise the
        # key the user believes now lives only in 1Password is still resident in
        # the OS keychain — the same orphan the symmetric `rm` path deliberately
        # avoids. If the backend is unavailable or the delete fails, keep the
        # existing routing (do not persist the op binding) and surface it so the
        # user can retry, rather than silently orphaning the keychain secret.
        existing = cfg.lookup(prov)
        if existing && existing[:backend] == "keychain"
          backend = pick_keychain_backend
          unless backend
            warn "No platform keychain available to delete #{prov.name}'s previously stored secret; " \
              "leaving the existing keychain routing in place. Install libsecret (`secret-tool`) on Linux."
            exit 1
          end
          unless backend.delete(prov.account)
            warn "Failed to delete #{prov.name}'s old secret from #{backend.name}; " \
              "leaving the existing keychain routing in place so the secret is not orphaned."
            exit 1
          end
        end

        # The op binding is a local auth.toml write, so — like bind_keychain in
        # provider_login — it can fail *after* the old keychain secret has
        # already been deleted above. A SystemCallError (EACCES/EROFS/ENOSPC
        # from mkdir_p/Tempfile/rename/flock) or a malformed-file Xbookmark::Error
        # here leaves the secret gone but the routing still pointing at keychain;
        # funnel it through warn+exit 1 instead of letting a raw backtrace escape.
        begin
          cfg.bind_one_password(prov, op_ref)
        rescue Xbookmark::Error, SystemCallError => e
          warn "Deleted #{prov.name}'s old keychain secret, but failed to record its " \
            "1Password routing in auth.toml: #{e.message}. Re-run " \
            "`xbookmark auth bind #{prov.name} #{op_ref}` once the config dir is writable."
          exit 1
        end

        puts "Bound #{prov.name} to #{op_ref}."
      end

      desc "list", "List configured provider credentials (never prints values)"
      def list
        cfg = load_auth_config
        rows = cfg.entries.map do |name, entry|
          [name, entry[:backend], entry[:ref].to_s]
        end

        # Map each XBOOKMARK_*_KEY env var to the provider the Resolver would
        # actually route it to. The legacy `XBOOKMARK_<NAME>_API_KEY` form is an
        # alias for provider `<name>` (not `<name>_api`), so it is classified
        # *before* the canonical `XBOOKMARK_<NAME>_KEY` pattern, which would
        # otherwise capture `<name>_api` and report a phantom provider.
        #
        # When both forms are set for one provider the Resolver prefers the
        # canonical key, so we collect both candidates per provider and report
        # the canonical one when present — otherwise `list` would name the
        # legacy var as the source while resolution used the canonical one.
        env_sources = {}
        ENV.keys.sort.each do |env_key|
          if (m = env_key.match(/\AXBOOKMARK_(.+)_API_KEY\z/))
            (env_sources[m[1].downcase] ||= {})[:legacy] = env_key
          elsif (m = env_key.match(/\AXBOOKMARK_(.+)_KEY\z/))
            (env_sources[m[1].downcase] ||= {})[:canonical] = env_key
          end
        end

        # The env-var name is derived by lowercasing the captured group, so a
        # provider's hyphens have already been collapsed to underscores by
        # `Provider#env_key` (`foo-bar` -> XBOOKMARK_FOO_BAR_KEY -> `foo_bar`).
        # Configured rows keep the hyphen, so compare in the underscore form or
        # a hyphenated provider that also exports its env var lists twice
        # (`foo-bar/keychain` + phantom `foo_bar/env`).
        env_rows = env_sources.filter_map do |name, sources|
          next if rows.any? { |r| r[0].tr("-", "_") == name }
          [name, "env", sources[:canonical] || sources[:legacy]]
        end

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
      long_desc <<~LONG
        Prints the resolved secret in plaintext to stdout. This is the only
        command that emits the key itself, so treat its output as sensitive:
        do not pipe it into log files, shell history, or anything that persists
        it. Use it for ad-hoc diagnostics or to feed a key into a process that
        consumes stdin, not as a logged build step.
      LONG
      def show(provider)
        require_relative "../keystore/provider"
        require_relative "../keystore/resolver"

        prov = parse_provider(provider)
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

        prov = parse_provider(provider)
        cfg = load_auth_config
        entry = cfg.lookup(prov)

        unless entry
          puts "#{prov.name} was not configured."
          return
        end

        # Delete the platform credential *first* so we never drop the auth.toml
        # routing while leaving an orphaned secret behind. If the backend is
        # unavailable or the delete fails, surface it and keep the routing so
        # the user can retry rather than silently orphaning the keychain row.
        if entry[:backend] == "keychain"
          backend = pick_keychain_backend
          unless backend
            warn "No platform keychain available to delete #{prov.name}'s stored secret; " \
              "leaving auth.toml routing in place. Install libsecret (`secret-tool`) on Linux."
            exit 1
          end
          unless backend.delete(prov.account)
            warn "Failed to delete #{prov.name} from #{backend.name}; " \
              "leaving auth.toml routing in place so the secret is not orphaned."
            exit 1
          end
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

      # Parse a provider name, surfacing the validation error as a clean
      # one-line message + exit 1 rather than letting Xbookmark::Error (a plain
      # StandardError, not a Thor::Error) escape as a raw backtrace. Shared by
      # every subcommand that takes a PROVIDER argument.
      def parse_provider(arg)
        require_relative "../keystore/provider"
        Xbookmark::Keystore::Provider.parse(arg)
      rescue Xbookmark::Error => e
        warn e.message
        exit 1
      end

      # Load auth.toml, surfacing a malformed-file error (raised by
      # AuthConfig#load_entries) as a clean one-line message + exit 1 rather
      # than a raw backtrace. These inspect/repair commands (`list`/`bind`/`rm`)
      # are exactly what a user reaches for when the file is broken, so they
      # must funnel the error the same way `show`/`parse_provider` do.
      def load_auth_config
        require_relative "../keystore/auth_config"
        Xbookmark::Keystore::AuthConfig.new
      rescue Xbookmark::Error => e
        warn e.message
        exit 1
      end

      def provider_login(provider_arg)
        require_relative "../keystore"
        require_relative "../keystore/provider"
        require_relative "../keystore/auth_config"
        require_relative "../keystore/keychain"
        require_relative "../keystore/libsecret"
        require_relative "../paths"

        prov = parse_provider(provider_arg)
        backend = pick_keychain_backend
        unless backend
          warn "No platform keychain available. " \
            "Install libsecret (`secret-tool`) on Linux, or use `xbookmark auth bind #{prov.name} op://...`."
          exit 1
        end

        value = read_secret_from_stdin("Enter #{prov.name} key (input hidden): ")
        # A nil return means stdin reached EOF / was closed before any line was
        # read (e.g. a broken pipe in a script), which is distinct from an
        # entered-but-empty line; report it separately to aid debugging.
        if value.nil?
          warn "No input received on stdin (EOF); nothing stored."
          exit 1
        end
        # Reject whitespace-only input, not just "", so the store-time emptiness
        # check matches the Resolver's `non_empty?` (which strips before
        # checking). Otherwise a pure-spaces secret would be written here yet
        # report "backend returned no value" at `auth show` time.
        if value.strip.empty?
          warn "No value entered; nothing stored."
          exit 1
        end

        # The store and the routing write fail in different ways and mean
        # different things, so rescue them separately. A backend.set failure
        # (locked keyring, secret-tool DBus error) means nothing was stored —
        # funnel it through warn+exit 1 like every other auth path instead of
        # letting a raw Xbookmark::Error backtrace escape after the user has
        # already typed their key into the hidden prompt.
        begin
          backend.set(prov.account, value)
        rescue Xbookmark::Error => e
          warn "Could not store #{prov.name} key in #{backend.name}: #{e.message}"
          exit 1
        end

        # bind_keychain is a local auth.toml write, so it fails *after* the
        # secret is already in the backend. A SystemCallError (EACCES/EROFS/
        # ENOSPC from mkdir_p/Tempfile/rename/flock) or a malformed-file
        # Xbookmark::Error here leaves the key stored but unrouted — name that
        # state explicitly instead of claiming the store failed or letting a raw
        # backtrace escape.
        begin
          Xbookmark::Keystore::AuthConfig.new.bind_keychain(prov)
        rescue Xbookmark::Error, SystemCallError => e
          warn "Stored #{prov.name} in #{backend.name}, but failed to record its routing " \
            "in auth.toml: #{e.message}. The secret is saved but unrouted; re-run " \
            "`xbookmark auth login #{prov.name}` once the config dir is writable."
          exit 1
        end
        puts "Stored #{prov.name} in #{backend.name}."
      end

      def pick_keychain_backend
        if Xbookmark::Paths.macos?
          Xbookmark::Keystore::Keychain.new
        elsif linux_libsecret_available?
          Xbookmark::Keystore::Libsecret.new
        end
      end

      # Mirror Resolver#linux_libsecret_available? and Keystore#libsecret_available?:
      # libsecret on Linux needs both the `secret-tool` binary *and* a live
      # D-Bus session. Probing only the binary made `auth login PROVIDER` accept
      # the hidden key prompt on a headless host, then fail at store time after
      # the user had already typed their secret.
      def linux_libsecret_available?
        return false unless Xbookmark::Paths.linux?
        return false if ENV["DBUS_SESSION_BUS_ADDRESS"].to_s.strip.empty?
        Xbookmark::Keystore::Libsecret.available?
      end

      def read_secret_from_stdin(prompt)
        $stderr.write(prompt)
        $stderr.flush
        if $stdin.tty? && $stdin.respond_to?(:noecho)
          # noecho manipulates the terminal via termios; on a closed or
          # non-restorable tty it raises a SystemCallError (e.g. Errno::ENOTTY)
          # *before* the user types. Abort loudly through warn+exit 1 rather than
          # letting a raw backtrace escape and possibly leave echo disabled.
          begin
            value = $stdin.noecho(&:gets)
          rescue SystemCallError => e
            warn "Could not disable terminal echo for hidden input: #{e.message}; nothing stored."
            exit 1
          end
          $stderr.puts
        else
          value = $stdin.gets
        end
        # `gets` returns nil at EOF / on a closed stdin; preserve that so the
        # caller can distinguish it from an entered-but-empty line.
        return nil if value.nil?
        value.chomp
      end
    end
  end
end
