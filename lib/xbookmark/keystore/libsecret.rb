# frozen_string_literal: true

require "open3"

module Xbookmark
  class Keystore
    # libsecret backend (Linux). Shells out to `secret-tool`.
    # All entries are tagged with attributes `service=xbookmark` and
    # `account=<key>` so we can enumerate them.
    class Libsecret
      def self.available?
        path = which("secret-tool")
        !path.nil?
      end

      def self.which(cmd)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          full = File.join(dir, cmd)
          return full if File.executable?(full) && !File.directory?(full)
        end
        nil
      end

      def name
        "libsecret"
      end

      def get(account)
        out, err, status = Open3.capture3(
          "secret-tool", "lookup",
          "service", Xbookmark::Keystore::SERVICE,
          "account", account.to_s
        )
        if status.success?
          return nil if out.to_s.empty?
          return out
        end
        # `secret-tool lookup` exits non-zero with no stderr when the item is
        # simply absent (a genuine "not found"). A non-empty stderr means a
        # transient failure — locked keyring, no D-Bus session — and collapsing
        # that to nil would mislead the Resolver into reporting the credential
        # as permanently missing and prompting a destructive overwrite. Surface
        # it instead.
        raise Xbookmark::Error,
          "secret-tool lookup failed: #{err.to_s.strip}" unless err.to_s.strip.empty?
        nil
      end

      def set(account, value)
        # `secret-tool store` reads the value from stdin to avoid leaking it
        # into the process listing.
        _out, err, status = Open3.capture3(
          "secret-tool", "store",
          "--label=xbookmark",
          "service", Xbookmark::Keystore::SERVICE,
          "account", account.to_s,
          stdin_data: value.to_s
        )
        return true if status.success?
        raise Xbookmark::Error, "secret-tool store failed: #{err}"
      end

      def delete(account)
        _out, _err, status = Open3.capture3(
          "secret-tool", "clear",
          "service", Xbookmark::Keystore::SERVICE,
          "account", account.to_s
        )
        status.success?
      end

      def list_accounts
        out, _err, status = Open3.capture3(
          "secret-tool", "search", "--all",
          "service", Xbookmark::Keystore::SERVICE
        )
        return [] unless status.success?
        accounts = []
        out.each_line do |line|
          if (m = line.match(/^attribute\.account\s*=\s*(.+)$/))
            accounts << m[1].strip
          end
        end
        accounts.uniq
      end
    end
  end
end
