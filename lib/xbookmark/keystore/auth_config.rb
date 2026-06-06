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

      def initialize(path: self.class.default_path)
        @path = path
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
          next unless section.is_a?(Hash)
          backend = section["backend"].to_s
          next if backend.empty?
          # Drop sections with an unrecognized backend instead of round-tripping
          # them silently; only KNOWN_BACKENDS can be resolved at runtime.
          next unless KNOWN_BACKENDS.include?(backend)
          entry = { backend: backend }
          entry[:ref] = section["ref"].to_s if section["ref"]
          entries[name.to_s.downcase] = entry
        end
        entries
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
