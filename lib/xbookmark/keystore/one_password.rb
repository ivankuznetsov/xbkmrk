# frozen_string_literal: true

require "open3"

module Xbookmark
  class Keystore
    # 1Password backend: resolves `op://...` references at runtime by
    # shelling out to the official `op` CLI.  The secret never lands on
    # disk inside xbookmark; the canonical store is 1Password itself.
    class OnePassword
      NOT_SIGNED_IN_HINT =
        "Run `op signin` first or set OP_SERVICE_ACCOUNT_TOKEN."

      def self.available?
        !which("op").nil?
      end

      def self.which(cmd)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          full = File.join(dir, cmd)
          return full if File.executable?(full) && !File.directory?(full)
        end
        nil
      end

      def name
        "1password"
      end

      def read(ref)
        ref = ref.to_s
        out, err, status = Open3.capture3("op", "read", "--no-newline", ref)
        return out if status.success?

        if err.to_s.include?("not signed in")
          raise Xbookmark::Error,
            "1Password CLI not signed in. #{NOT_SIGNED_IN_HINT}"
        end

        raise Xbookmark::Error,
          "op read #{ref} failed: #{err.to_s.strip}"
      end
    end
  end
end
