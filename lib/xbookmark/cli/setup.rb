# frozen_string_literal: true

require "thor"
require "fileutils"
require "io/console"
require_relative "../paths"
require_relative "../keystore"
require_relative "../keystore/importer"
require_relative "../scheduler/installer"
require_relative "../config"

module Xbookmark
  class CLI
    class Setup < Thor::Group
      # The prompted env keys, in the order the wizard asks for them.
      # Mirrors `Config::REQUIRED_KEYS` for the truly required slots and
      # extends with the optional-but-recommended ones.
      PROMPTS = [
        ["OPENROUTER_API_KEY", "OpenRouter API key", true, true],
        ["X_CLIENT_ID",     "X API client ID (optional)",     false, false],
        ["X_USER_ID",       "X numeric user ID (optional)",   false, false],
        ["X_CLIENT_SECRET", "X API client secret", false, true],
        ["X_REDIRECT_URI",  "OAuth redirect URI",  false, false]
      ].freeze

      attr_reader :options

      def initialize(args = [], options = {}, _config = {})
        super
        @options  = options
        @input    = options[:input]  || $stdin
        @output   = options[:output] || $stdout
        @keystore = options[:keystore] || Xbookmark::Keystore.default
        @scheduler = options[:scheduler] # injected installer for tests
      end

      def execute
        unless interactive?
          say "[xbookmark] non-interactive shell; run 'xbookmark setup' to configure"
          return 0
        end

        say "[xbookmark] setup wizard"
        say "  keystore backend: #{@keystore.backend_name}"

        legacy_env = detect_legacy_env
        if legacy_env
          import_legacy_env(legacy_env)
        end

        prompt_for_missing_keys

        install_scheduler

        say ""
        say "[xbookmark] setup complete. Run `xbookmark doctor` to confirm."
        0
      end

      # Returns 0 when the wizard is satisfied; non-zero otherwise.
      # Used by the first-run hook before invoking any other subcommand.
      def self.first_run_check!(input: $stdin, output: $stdout, keystore: Xbookmark::Keystore.default)
        return 0 if first_run_configured?(keystore: keystore)
        return 0 unless input.respond_to?(:tty?) && input.tty?
        output.puts "[xbookmark] first run detected — launching setup wizard."
        new([], input: input, output: output, keystore: keystore).execute
      end

      def self.first_run_configured?(keystore: Xbookmark::Keystore.default)
        configured?(keystore: keystore) || env_file_configured?
      end

      def self.configured?(keystore: Xbookmark::Keystore.default)
        Xbookmark::Config::ENRICHMENT_KEYS.all? { |k| !keystore.get(k).to_s.empty? }
      end

      def self.env_file_configured?
        env = ENV.to_h.dup
        Xbookmark::Config.load_env_files!(cwd: Dir.pwd, env: env)
        Xbookmark::Config::ENRICHMENT_KEYS.all? { |k| env[k] && !env[k].to_s.strip.empty? }
      rescue StandardError
        false
      end

      private

      def interactive?
        return false if ENV["XBOOKMARK_TEST"] == "1" && !options[:force_interactive]
        @input.respond_to?(:tty?) && @input.tty?
      rescue StandardError
        false
      end

      def detect_legacy_env
        [Xbookmark::Paths.project_env_path, Xbookmark::Paths.user_env_path].find { |p| File.file?(p) }
      end

      def import_legacy_env(path)
        say ""
        say "Found legacy .env at #{path}."
        return unless yes_no?("Import its keys into the keystore?", default: true)

        migrated = Xbookmark::Keystore::Importer.new(keystore: @keystore).import(path)
        if migrated.empty?
          say "  no known keys found in #{path}; nothing imported."
        else
          say "  imported: #{migrated.join(", ")}"
          if yes_no?("Delete #{path} now that the keystore has the values?", default: false)
            File.delete(path)
            say "  deleted #{path}"
          end
        end
      end

      def prompt_for_missing_keys
        PROMPTS.each do |env_key, label, required, secret|
          current = @keystore.get(env_key)
          if current && !current.to_s.empty?
            say "#{env_key}: already set (skipping)"
            next
          end
          value = prompt("#{label} (#{env_key}): ", secret: secret)
          if value.empty?
            if required
              raise Xbookmark::ConfigError, "#{env_key} is required"
            else
              next
            end
          end
          @keystore.set(env_key, value)
        end
      end

      def install_scheduler
        say ""
        unless x_sync_configured?
          say "  X credentials not configured; scheduler not installed (Birdclaw-only mode)"
          return
        end

        installer = @scheduler || begin
          config = Xbookmark::Config.load
          Xbookmark::Scheduler::Installer.new(config: config)
        end
        installer.install
        say "  scheduler installed"
      rescue StandardError => e
        say "  scheduler install failed: #{e.message}"
      end

      def x_sync_configured?
        Xbookmark::Config::REQUIRED_KEYS.all? { |key| !@keystore.get(key).to_s.strip.empty? }
      end

      def prompt(label, secret: false)
        @output.print(label)
        @output.flush if @output.respond_to?(:flush)
        line = read_line(secret: secret)
        line.to_s.strip
      end

      def read_line(secret: false)
        if secret && @input.respond_to?(:noecho) && @input.tty?
          value = @input.noecho(&:gets)
          @output.puts
          value
        else
          @input.gets
        end
      end

      def yes_no?(label, default: true)
        suffix = default ? "[Y/n]" : "[y/N]"
        @output.print("#{label} #{suffix} ")
        @output.flush if @output.respond_to?(:flush)
        answer = @input.gets.to_s.strip.downcase
        return default if answer.empty?
        return true  if answer == "y" || answer == "yes"
        return false if answer == "n" || answer == "no"
        default
      end

      def say(line)
        @output.puts(line)
      end
    end
  end
end
