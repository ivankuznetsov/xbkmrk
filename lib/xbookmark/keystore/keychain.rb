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
        # A genuine "not stored" exits non-zero with no diagnostic on stderr;
        # collapse only that to nil. A non-empty stderr means something
        # transient went wrong (e.g. a locked keychain that failed to unlock) —
        # surfacing it stops the Resolver from reporting a still-present secret
        # as permanently missing and prompting a destructive re-login overwrite.
        # (The exact not-found exit code is assumed, not verified — see
        # wiki/gaps.md.)
        raise Xbookmark::Error,
          "security find-generic-password failed: #{err.to_s.strip}" unless err.to_s.strip.empty?
        nil
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
        # exit 44 == errSecItemNotFound: there is nothing to delete, so report
        # success. This lets `auth rm` clear stale auth.toml routing after the
        # secret was already removed out-of-band, instead of wedging on a
        # missing item (no secret can be orphaned when none exists).
        status.exitstatus == 44
      end

      def list_accounts
        # `security` cannot enumerate all items for a service in a stable
        # parseable form, so we probe the known account list and report
        # which ones exist.
        Xbookmark::Keystore::KNOWN_KEYS.select { |a| !get(a).nil? }
      end
    end
  end
end
