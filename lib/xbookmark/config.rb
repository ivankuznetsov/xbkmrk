# frozen_string_literal: true

require "dotenv"
require_relative "enrich/defaults"

module Xbookmark
  class Config
    REQUIRED_KEYS = %w[X_CLIENT_ID X_USER_ID].freeze
    ENRICHMENT_KEYS = %w[OPENROUTER_API_KEY].freeze

    Struct.new(
      "XbookmarkConfig",
      :vault_path,
      :state_db_path,
      :logs_dir,
      :scratch_dir,
      :x_client_id,
      :x_client_secret,
      :x_redirect_uri,
      :x_user_id,
      :x_access_token,
      :x_refresh_token,
      :x_token_expires_at,
      :codex_bin,
      :openrouter_api_key,
      :openrouter_text_model,
      :openrouter_vision_model,
      :openrouter_image_detail,
      :birdclaw_db_path,
      :whisper_bin,
      :whisper_model,
      :qmd_bin,
      :daily_sync_time,
      :min_run_interval_hours,
      :aux_summaries,
      :taxonomy_maintenance,
      :env_file,
      :verbose,
      keyword_init: true
    ) unless defined?(Struct::XbookmarkConfig)

    class << self
      def load(wiki_override: nil, vault_override: nil, cwd: Dir.pwd, env: ENV.to_h.dup, verbose: false, keystore: :auto)
        loaded_env_files = load_env_files!(cwd: cwd, env: env)
        hydrate_from_keystore!(env, keystore: keystore)
        validate_required!(env)

        build_config(env, loaded_env_files: loaded_env_files, wiki_override: wiki_override,
                          vault_override: vault_override, verbose: verbose)
      end

      def load_offline(wiki_override: nil, vault_override: nil, cwd: Dir.pwd, env: ENV.to_h.dup, verbose: false, keystore: :auto)
        loaded_env_files = load_env_files!(cwd: cwd, env: env)
        hydrate_from_keystore!(env, keystore: keystore)
        build_config(env, loaded_env_files: loaded_env_files, wiki_override: wiki_override,
                          vault_override: vault_override, verbose: verbose)
      end

      def build_config(env, loaded_env_files:, wiki_override:, vault_override:, verbose:)
        vault_path = first_present(wiki_override, vault_override, configured_wiki_path(env)) || default_wiki_dir(env)
        vault_path = File.expand_path(vault_path)

        state_db_path = File.join(vault_path, ".xbookmark", "state.db")
        scratch_dir   = File.join(vault_path, ".xbookmark", "scratch")
        logs_dir      = env["XBOOKMARK_LOGS_DIR"] || default_logs_dir(env)

        Struct::XbookmarkConfig.new(
          vault_path: vault_path,
          state_db_path: state_db_path,
          logs_dir: File.expand_path(logs_dir),
          scratch_dir: scratch_dir,
          x_client_id: env["X_CLIENT_ID"],
          x_client_secret: env["X_CLIENT_SECRET"],
          x_redirect_uri: env["X_REDIRECT_URI"] || default_redirect_uri,
          x_user_id: env["X_USER_ID"],
          x_access_token: env["X_ACCESS_TOKEN"],
          x_refresh_token: env["X_REFRESH_TOKEN"],
          x_token_expires_at: parse_int_or_nil(env["X_TOKEN_EXPIRES_AT"]),
          codex_bin: env["CODEX_BIN"] || "codex",
          openrouter_api_key: first_present(env["OPENROUTER_API_KEY"], env["XBOOKMARK_OPENROUTER_KEY"]),
          openrouter_text_model: env["OPENROUTER_TEXT_MODEL"] || Xbookmark::Enrich::Defaults::TEXT_MODEL,
          openrouter_vision_model: env["OPENROUTER_VISION_MODEL"] || Xbookmark::Enrich::Defaults::VISION_MODEL,
          openrouter_image_detail: env["OPENROUTER_IMAGE_DETAIL"] || Xbookmark::Enrich::Defaults::IMAGE_DETAIL,
          birdclaw_db_path: File.expand_path(env["BIRDCLAW_DB_PATH"] || File.join(Paths.home, ".birdclaw", "birdclaw.sqlite")),
          whisper_bin: env["WHISPER_BIN"],
          whisper_model: env["WHISPER_MODEL"] || "base.en",
          qmd_bin: env["QMD_BIN"] || "qmd",
          daily_sync_time: env["XBOOKMARK_DAILY_TIME"] || "06:00",
          min_run_interval_hours: (env["XBOOKMARK_MIN_RUN_INTERVAL_HOURS"] || "20").to_f,
          aux_summaries: truthy?(env["XBOOKMARK_AUX_SUMMARIES"]),
          taxonomy_maintenance: !falsey?(env["XBOOKMARK_TAXONOMY_MAINTENANCE"]),
          env_file: loaded_env_files.first,
          verbose: verbose
        )
      end

      def load_env_files!(cwd:, env:)
        explicit = env["XBOOKMARK_ENV_FILE"]
        candidates = [
          (explicit unless explicit.to_s.strip.empty?),
          Paths.project_env_path(cwd: cwd),
          Paths.user_env_path
        ].compact.uniq

        loaded = []
        candidates.each do |path|
          next unless File.file?(path)
          parsed = ::Dotenv.parse(path)
          parsed.each do |k, v|
            env[k] = v unless env.key?(k)
          end
          loaded << path
        end
        loaded
      end

      # Pull any KNOWN_KEYS values out of the keystore that are not
      # already set in `env`.  `keystore:` may be:
      #   :auto  — pick the default backend (libsecret / Keychain / env_file)
      #   nil    — skip keystore hydration entirely
      #   Object — any object responding to `hydrate(env)`
      def hydrate_from_keystore!(env, keystore:)
        return if keystore.nil?
        store =
          if keystore == :auto
            require_relative "keystore"
            begin
              Xbookmark::Keystore.default
            rescue StandardError
              return
            end
          else
            keystore
          end
        store.hydrate(env)
      rescue StandardError
        # The keystore is best-effort; never let a backend failure
        # block config loading.  The fallback chain in `validate_required!`
        # will surface the real "missing key" message instead.
      end

      def validate_required!(env)
        missing = REQUIRED_KEYS.reject { |k| env[k] && !env[k].to_s.strip.empty? }
        return if missing.empty?
        raise ConfigError, "Missing required env keys: #{missing.join(", ")}. " \
          "Copy .env.example to .env and fill in the values."
      end

      def parse_int_or_nil(value)
        return nil if value.nil? || value.to_s.strip.empty?
        Integer(value)
      rescue ArgumentError
        nil
      end

      def truthy?(value)
        %w[1 true yes on].include?(value.to_s.strip.downcase)
      end

      def falsey?(value)
        %w[0 false no off].include?(value.to_s.strip.downcase)
      end

      def configured_wiki_path(env)
        first_present(env["XBOOKMARK_WIKI_PATH"], env["XBOOKMARK_VAULT"], env["OBSIDIAN_VAULT_PATH"])
      end

      def first_present(*values)
        values.find { |value| value && !value.to_s.strip.empty? }
      end

      def default_wiki_dir(env)
        if Paths.macos? && env["XDG_DATA_HOME"].to_s.empty?
          File.join(Paths.home, "Library", "Application Support", "xbookmark-wiki")
        elsif env["XDG_DATA_HOME"] && !env["XDG_DATA_HOME"].to_s.empty?
          File.join(env["XDG_DATA_HOME"], "xbookmark-wiki")
        else
          File.join(Paths.home, ".local", "share", "xbookmark-wiki")
        end
      end

      def default_redirect_uri
        # Single source of truth for the local OAuth callback port —
        # mirroring this string drifts out of sync with Auth::LOCAL_PORT.
        require_relative "x/auth"
        "http://127.0.0.1:#{Xbookmark::X::Auth::LOCAL_PORT}/callback"
      end

      def default_logs_dir(env)
        if Paths.macos? && env["XDG_STATE_HOME"].to_s.empty?
          File.join(Paths.home, "Library", "Logs", "xbookmark")
        elsif env["XDG_STATE_HOME"] && !env["XDG_STATE_HOME"].to_s.empty?
          File.join(env["XDG_STATE_HOME"], "xbookmark")
        else
          File.join(Paths.home, ".local", "state", "xbookmark")
        end
      end
    end
  end
end
