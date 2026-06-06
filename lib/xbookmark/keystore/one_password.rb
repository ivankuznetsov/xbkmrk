# frozen_string_literal: true

require "open3"
require "timeout"

module Xbookmark
  class Keystore
    # 1Password backend: resolves `op://...` references at runtime by
    # shelling out to the official `op` CLI.  The secret never lands on
    # disk inside xbookmark; the canonical store is 1Password itself.
    class OnePassword
      # Raised when `op` is installed but no session is active. Callers (e.g.
      # `auth bind`'s smoke-check) treat this differently from a bad reference:
      # not-signed-in is a warn-and-continue condition, a bad ref is fatal.
      class NotSignedInError < Xbookmark::Error; end

      NOT_SIGNED_IN_HINT =
        "Run `op signin` first or set OP_SERVICE_ACCOUNT_TOKEN."

      # Cap the shell-out so an installed-but-not-signed-in `op` that prompts
      # interactively cannot block a non-interactive command indefinitely
      # (matches the timeout the codex wrapper uses).
      DEFAULT_TIMEOUT = 10

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

      def read(ref, timeout: DEFAULT_TIMEOUT)
        ref = ref.to_s
        out, err, status =
          begin
            Timeout.timeout(timeout) do
              Open3.capture3("op", "read", "--no-newline", ref)
            end
          rescue Timeout::Error
            raise Xbookmark::Error,
              "op read #{ref} timed out after #{timeout}s. #{NOT_SIGNED_IN_HINT}"
          end

        if status.success?
          # An `op://` ref can point at an empty field; reject blank output so
          # the value agrees with Resolver#non_empty? and a bind smoke-check
          # cannot pass on an empty secret.
          raise Xbookmark::Error, "op read #{ref} returned an empty value" if out.to_s.strip.empty?
          return out
        end

        if err.to_s.include?("not signed in")
          raise NotSignedInError,
            "1Password CLI not signed in. #{NOT_SIGNED_IN_HINT}"
        end

        raise Xbookmark::Error,
          "op read #{ref} failed: #{err.to_s.strip}"
      end
    end
  end
end
