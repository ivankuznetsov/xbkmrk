# frozen_string_literal: true

require "fileutils"
require "tempfile"
require "tomlrb"

require_relative "../paths"
require_relative "provider"

module Xbookmark
  class Keystore
    # Read/write the auth routing file (default
    # `$XDG_CONFIG_HOME/xbookmark/auth.toml`, i.e.
    # `~/.config/xbookmark/auth.toml` when XDG_CONFIG_HOME is unset — see
    # Paths.default_config_dir).
    #
    # The file is the *only* on-disk artifact this layer adds. It never holds
    # secret values; it only records which backend each provider uses and,
    # for 1Password, the `op://` reference (which is sensitive routing data,
    # so we still write the file with mode 0600).
    class AuthConfig
      KNOWN_BACKENDS = %w[keychain 1password].freeze

      attr_reader :path

      def self.default_path
        File.join(Xbookmark::Paths.default_config_dir, "auth.toml")
      end

      def initialize(path: self.class.default_path, warn_io: $stderr)
        @path = path
        @warn_io = warn_io
        @entries = load_entries
      end

      def entries
        # Return a deep copy so callers cannot mutate our internal state by
        # accident.  Tiny hash, no perf concern.
        @entries.transform_values { |h| h.dup }
      end

      def lookup(provider)
        key = provider_key(provider)
        entry = @entries[key]
        entry && entry.dup
      end

      def bind_keychain(provider)
        key = provider_key(provider)
        update! { |entries| entries[key] = { backend: "keychain" } }
        true
      end

      def bind_one_password(provider, ref)
        ref = ref.to_s
        unless ref.start_with?("op://")
          raise Xbookmark::Error,
            "1Password reference must start with op:// (got #{ref.inspect})"
        end
        key = provider_key(provider)
        update! { |entries| entries[key] = { backend: "1password", ref: ref } }
        true
      end

      def remove(provider)
        key = provider_key(provider)
        removed = false
        update! { |entries| removed = !entries.delete(key).nil? }
        removed
      end

      private

      # Read-modify-write under an exclusive lock so two AuthConfig instances
      # that started from the same on-disk state cannot clobber each other's
      # provider rows.  We re-read the file *inside* the lock (rather than
      # serializing our possibly-stale @entries before taking it), apply the
      # mutation to the freshly-loaded copy, then atomically rename into place.
      def update!
        FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
        # The `auth.toml.lock` file is created on first write and deliberately
        # left in place afterwards (it lives alongside auth.toml in the config
        # dir). Unlinking it on release would reintroduce the classic flock
        # race — a second process can be holding the same inode while we delete
        # and recreate the path, so two writers could end up locking different
        # inodes. The empty lockfile is harmless clutter; leaving it is correct.
        lock_path = "#{@path}.lock"
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          entries = load_entries
          yield entries
          content = serialize(entries)
          tmp = Tempfile.new(["auth", ".toml"], File.dirname(@path))
          begin
            tmp.write(content)
            tmp.close
            File.chmod(0o600, tmp.path)
            File.rename(tmp.path, @path)
          ensure
            tmp.close! unless tmp.closed?
            File.unlink(tmp.path) if File.exist?(tmp.path)
          end
          @entries = entries
        end
        true
      end

      def provider_key(provider)
        return provider.account if provider.respond_to?(:account)
        # Normalize a raw String through the same door the Resolver uses, so a
        # value written here can never disagree with what `Provider.parse`
        # considers a legal key (and an injection-y name like `]` or a newline
        # is rejected before it can reach the `[#{name}]` section header).
        Provider.parse(provider).account
      end

      def load_entries
        return {} unless File.file?(@path)
        raw =
          begin
            Tomlrb.parse(File.read(@path))
          rescue Tomlrb::ParseError => e
            raise Xbookmark::Error,
              "malformed auth.toml at #{@path}: #{e.message}. " \
                "Fix or remove the file and re-run `xbookmark auth login`."
          end
        entries = {}
        raw.each do |name, section|
          key = name.to_s.downcase
          # We *warn* on every dropped section rather than skipping silently:
          # update! re-reads then re-serialises only the survivors, so a
          # hand-added or typo'd row would otherwise be deleted as a side effect
          # of an unrelated `bind`/`rm`/`login`, with the user only finding out
          # at resolve time via a confusing "No credential configured".
          unless section.is_a?(Hash)
            warn_dropped(name, "expected a [section] table")
            next
          end
          # Reuse Provider's single source of truth for the legal-name charset
          # (the same shape Provider.parse enforces) so the two cannot drift. A
          # name outside it (e.g. a quoted/dotted TOML key) cannot round-trip
          # through serialize's bare `[#{name}]` header, so we reject it here.
          unless key.match?(Provider::NAME_PATTERN)
            # A quoted/dotted TOML key (e.g. ["foo bar"] or [a.b]) is legal on
            # disk but cannot round-trip through serialize's bare `[#{name}]`
            # header — it would rewrite to an unparseable file and brick every
            # subsequent auth command. Drop it loudly instead.
            warn_dropped(name, "not a valid provider name (must match /\\A[a-z0-9_-]+\\z/)")
            next
          end
          backend = section["backend"].to_s
          if backend.empty?
            warn_dropped(name, "missing a backend")
            next
          end
          # Drop sections with an unrecognized backend instead of round-tripping
          # them silently; only KNOWN_BACKENDS can be resolved at runtime.
          unless KNOWN_BACKENDS.include?(backend)
            warn_dropped(name, "unknown backend #{backend.inspect}")
            next
          end
          ref = section["ref"]
          if backend == "1password" && (ref.nil? || ref.to_s.strip.empty?)
            # Enforce the "ref required iff 1password" invariant at load: a
            # ref-less 1password row would otherwise reach the Resolver and
            # shell `op read` with no reference, surfacing a confusing `op`
            # error rather than a clear malformed-config one.
            warn_dropped(name, "1password backend requires a ref")
            next
          end
          entry = { backend: backend }
          entry[:ref] = ref.to_s if ref
          entries[key] = entry
        end
        entries
      end

      def warn_dropped(name, reason)
        @warn_io&.puts(
          "[xbookmark] ignoring auth.toml section [#{name}]: #{reason}. " \
            "It will be removed on the next auth write."
        )
      end

      def serialize(entries)
        return "" if entries.empty?
        sorted = entries.sort_by { |k, _| k }
        sorted.map { |name, entry|
          lines = ["[#{name}]", %(backend = "#{escape_toml(entry[:backend])}")]
          lines << %(ref = "#{escape_toml(entry[:ref])}") if entry[:ref]
          lines.join("\n")
        }.join("\n\n") + "\n"
      end

      def escape_toml(str)
        # Escape everything a TOML basic string requires: backslash, double
        # quote, the named control-char escapes, and \uXXXX for any other
        # control byte.  `ref` is only validated as `op://...`, so a stray
        # newline/control char must not be written raw or the file becomes
        # unparseable (and would compound the load-time parse failure).
        str.to_s.gsub(/[\\"\x00-\x1f\x7f]/) do |ch|
          case ch
          when "\\" then "\\\\"
          when '"' then '\\"'
          when "\b" then "\\b"
          when "\t" then "\\t"
          when "\n" then "\\n"
          when "\f" then "\\f"
          when "\r" then "\\r"
          else format("\\u%04X", ch.ord)
          end
        end
      end
    end
  end
end
