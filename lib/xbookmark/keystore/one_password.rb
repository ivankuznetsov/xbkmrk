# frozen_string_literal: true

require "open3"

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

      # Raised when the `op` shell-out exceeds DEFAULT_TIMEOUT. Like
      # NotSignedInError, `auth bind`'s smoke-check treats this as
      # warn-and-continue: a slow vault is not evidence the ref is broken.
      class TimeoutError < Xbookmark::Error; end

      NOT_SIGNED_IN_HINT =
        "Run `op signin` first or set OP_SERVICE_ACCOUNT_TOKEN."

      # Match 1Password's "not signed in" family case-insensitively so a minor
      # wording/casing change in `op` (e.g. "not currently signed in") does not
      # silently reclassify the warn-and-continue case as a fatal error. The
      # exact substring is pinned by a test.
      NOT_SIGNED_IN_PATTERN = /not\s+(?:currently\s+)?signed[\s-]?in/.freeze

      # Cap the shell-out so an installed-but-not-signed-in `op` that prompts
      # interactively cannot block a non-interactive command indefinitely.
      DEFAULT_TIMEOUT = 10

      # Grace period after `TERM` before escalating to `KILL` when reaping a
      # timed-out `op` child. An `op` that traps/ignores `TERM` or is blocked
      # on `/dev/tty` would otherwise keep the post-TERM reap join blocking
      # forever, re-hanging the very caller DEFAULT_TIMEOUT is meant to cap.
      TERM_GRACE = 2

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
        out, err, status = run_op_read(ref, timeout)

        if status.success?
          # An `op://` ref can point at an empty field; reject blank output so
          # the value agrees with Resolver#non_empty? and a bind smoke-check
          # cannot pass on an empty secret.
          raise Xbookmark::Error, "op read #{ref} returned an empty value" if out.to_s.strip.empty?
          return out
        end

        if err.to_s.downcase.match?(NOT_SIGNED_IN_PATTERN)
          raise NotSignedInError,
            "1Password CLI not signed in. #{NOT_SIGNED_IN_HINT}"
        end

        raise Xbookmark::Error,
          "op read #{ref} failed: #{err.to_s.strip}"
      end

      private

      # Shell out to `op read` with a hard wall-clock cap. We use popen3 (not
      # capture3) so we hold the child's pid: on timeout we must kill and reap
      # the `op` process ourselves. `op` can open /dev/tty directly to prompt
      # interactively, so closing its stdin pipe would not unblock it — a bare
      # Timeout would unwind the Ruby caller but leak the child past the cap.
      def run_op_read(ref, timeout)
        stdin, stdout, stderr, wait_thr = Open3.popen3("op", "read", "--no-newline", ref)
        stdin.close
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }
        if wait_thr.join(timeout).nil?
          terminate(wait_thr)
          out_reader.kill
          err_reader.kill
          raise TimeoutError,
            "op read #{ref} timed out after #{timeout}s. #{NOT_SIGNED_IN_HINT}"
        end
        [out_reader.value, err_reader.value, wait_thr.value]
      ensure
        [stdout, stderr].each { |io| io.close if io && !io.closed? }
      end

      # Terminate and reap the timed-out `op` child so the cap actually stops
      # the subprocess instead of orphaning it. `TERM` first, but bound the reap
      # join to TERM_GRACE and escalate to an un-ignorable `KILL` if the child
      # outlives it — otherwise an `op` that traps/ignores `TERM` (or is blocked
      # on `/dev/tty`) would leave the join blocking forever, defeating the
      # wall-clock cap and re-hanging `auth bind`/resolve.
      def terminate(wait_thr, grace: TERM_GRACE)
        Process.kill("TERM", wait_thr.pid)
        return unless wait_thr.join(grace).nil?

        Process.kill("KILL", wait_thr.pid)
        wait_thr.join
      rescue Errno::ESRCH
        # The child already exited between the timeout and our signal; nothing
        # left to kill or reap.
      end
    end
  end
end
