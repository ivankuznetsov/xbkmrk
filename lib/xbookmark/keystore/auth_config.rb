# frozen_string_literal: true

require "fileutils"
require "tempfile"
require "tomlrb"

require_relative "../paths"

module Xbookmark
  class Keystore
    # Read/write `~/.config/xbookmark/auth.toml`.
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
        @entries[key] = { backend: "keychain" }
        save!
      end

      def bind_one_password(provider, ref)
        ref = ref.to_s
        unless ref.start_with?("op://")
          raise Xbookmark::Error,
            "1Password reference must start with op:// (got #{ref.inspect})"
        end
        key = provider_key(provider)
        @entries[key] = { backend: "1password", ref: ref }
        save!
      end

      def remove(provider)
        key = provider_key(provider)
        return false unless @entries.key?(key)
        @entries.delete(key)
        save!
        true
      end

      def save!
        FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
        content = serialize(@entries)

        # Atomic write: tmpfile in the same dir, then rename.  Hold an
        # exclusive lock on a sibling lockfile so two `auth bind` invocations
        # cannot clobber each other.
        lock_path = "#{@path}.lock"
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
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
        end
        true
      end

      private

      def provider_key(provider)
        return provider.account if provider.respond_to?(:account)
        provider.to_s.downcase
      end

      def load_entries
        return {} unless File.file?(@path)
        raw = Tomlrb.parse(File.read(@path))
        entries = {}
        raw.each do |name, section|
          next unless section.is_a?(Hash)
          backend = section["backend"].to_s
          next if backend.empty?
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
        # TOML basic-string escapes: backslash and double-quote are the only
        # ones we can hit in a backend name or op:// ref.
        str.to_s.gsub("\\", "\\\\\\\\").gsub('"', '\\"')
      end
    end
  end
end
