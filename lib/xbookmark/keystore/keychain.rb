# frozen_string_literal: true

require "open3"

module Xbookmark
  class Keystore
    # macOS Keychain backend.  Shells out to `security` from Apple's
    # Security framework.
    class Keychain
      def name
        "keychain"
      end

      def get(account)
        out, err, status = Open3.capture3(
          "security", "find-generic-password",
          "-s", Xbookmark::Keystore::SERVICE, "-a", account.to_s, "-w"
        )
        if status.success?
          value = out.to_s.chomp
          return value.empty? ? nil : value
        end
        # A signal-killed `security` has no exit status (exitstatus is nil);
        # that is never a clean "not found", so surface it rather than masking
        # it as an absent secret and prompting a destructive re-login overwrite.
        if status.exitstatus.nil?
          raise Xbookmark::Error,
            "security find-generic-password terminated abnormally (killed by a signal)"
        end
        # exit 44 == errSecItemNotFound: the credential is genuinely absent, so
        # collapse it to nil. Real `security` *also writes* "The specified item
        # could not be found in the keychain." to stderr on a miss, so we key
        # off the exit code (mirroring `delete`'s exit-44 tolerance) rather than
        # an empty stderr. Any other non-zero exit is a transient failure (e.g.
        # a locked keychain that failed to unlock) — surface it so the Resolver
        # does not report a still-present secret as permanently missing and
        # prompt a destructive re-login overwrite.
        return nil if status.exitstatus == 44
        raise Xbookmark::Error,
          "security find-generic-password failed: #{err.to_s.strip}"
      end

      def set(account, value)
        # -U updates if it already exists; -w sets the value.  We pass the
        # value via -w on the command line because `security` does not read
        # generic passwords from stdin.  This is the same shape used by the
        # macOS Keychain CLI throughout Apple's own docs.
        _out, err, status = Open3.capture3(
          "security", "add-generic-password",
          "-s", Xbookmark::Keystore::SERVICE,
          "-a", account.to_s,
          "-w", value.to_s,
          "-U"
        )
        return true if status.success?
        raise Xbookmark::Error, "security add-generic-password failed: #{err}"
      end

      def delete(account)
        _out, _err, status = Open3.capture3(
          "security", "delete-generic-password",
          "-s", Xbookmark::Keystore::SERVICE, "-a", account.to_s
        )
        return true if status.success?
        # A signal-killed `security` has no exit status (exitstatus is nil);
        # that is never a clean "not found", so surface it (mirroring `get`)
        # rather than letting `auth rm` print a misleading "Failed to delete"
        # that hides the abnormal termination from the user.
        if status.exitstatus.nil?
          raise Xbookmark::Error,
            "security delete-generic-password terminated abnormally (killed by a signal)"
        end
        # exit 44 == errSecItemNotFound: there is nothing to delete, so report
        # success. This lets `auth rm` clear stale auth.toml routing after the
        # secret was already removed out-of-band, instead of wedging on a
        # missing item (no secret can be orphaned when none exists).
        status.exitstatus == 44
      end

      def list_accounts
        # `security` cannot enumerate all items for a service in a stable
        # parseable form, so we probe the known account list and report
        # which ones exist. NOTE: this only covers KNOWN_KEYS (the legacy X
        # OAuth accounts); it is blind to provider rows added via `auth login`
        # (e.g. `openrouter`), so a caller must not assume it lists those.
        Xbookmark::Keystore::KNOWN_KEYS.select { |a| !get(a).nil? }
      end
    end
  end
end
