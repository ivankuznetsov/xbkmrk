# frozen_string_literal: true

# Pull in the top-level error hierarchy so requiring this file (or anything
# under keystore/) standalone defines Xbookmark::Error, which the backends
# raise. Without it, a caller that loads only the keystore would hit a
# NameError the first time a backend reported a failure.
require_relative "../xbookmark"
require_relative "paths"
require_relative "keystore/libsecret"
require_relative "keystore/keychain"
require_relative "keystore/env_file"
require_relative "keystore/memory"

module Xbookmark
  class Keystore
    SERVICE = "xbookmark"

    # Account names align with the env-var form (lowercased) so the
    # backend layer can shell out without re-mapping.
    KNOWN_KEYS = %w[
      x_client_id
      x_client_secret
      x_user_id
      x_redirect_uri
      x_access_token
      x_refresh_token
      x_token_expires_at
    ].freeze

    # Map ENV-style key -> lowercase keystore account name.
    def self.account_for(env_key)
      env_key.to_s.downcase
    end

    def self.env_key_for(account)
      account.to_s.upcase
    end

    class << self
      def default
        @default ||= new
      end

      # For test reset.
      def reset_default!
        @default = nil
      end
    end

    attr_reader :backend

    def initialize(backend: nil)
      @backend = backend || pick_backend
    end

    def backend_name
      @backend.name
    end

    def get(key)
      @backend.get(Keystore.account_for(key))
    end

    def set(key, value)
      @backend.set(Keystore.account_for(key), value)
    end

    def delete(key)
      @backend.delete(Keystore.account_for(key))
    end

    def list_keys
      @backend.list_accounts
    end

    # Remove all known xbookmark entries.  Returns the list of accounts
    # that were actually deleted (existed prior).
    def delete_all
      removed = []
      KNOWN_KEYS.each do |account|
        if @backend.get(account)
          @backend.delete(account)
          removed << account
        end
      end
      removed
    end

    # Populate `env` (a Hash, default ENV-style) with any keys present
    # in the keystore that are not already set there.  Returns the
    # hash so callers can chain.
    def hydrate(env = {})
      KNOWN_KEYS.each do |account|
        env_key = Keystore.env_key_for(account)
        next if env[env_key] && !env[env_key].to_s.strip.empty?
        value = @backend.get(account)
        env[env_key] = value if value && !value.to_s.empty?
      end
      env
    end

    private

    def pick_backend
      if Xbookmark::Paths.macos?
        Keychain.new
      elsif libsecret_available?
        Libsecret.new
      else
        EnvFile.new
      end
    end

    def libsecret_available?
      return false unless Xbookmark::Paths.linux?
      return false unless ENV["DBUS_SESSION_BUS_ADDRESS"] && !ENV["DBUS_SESSION_BUS_ADDRESS"].to_s.strip.empty?
      Libsecret.available?
    end
  end
end
