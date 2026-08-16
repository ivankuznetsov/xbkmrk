# frozen_string_literal: true

require "thor"
require_relative "../xbookmark"

module Xbookmark
  class CLI < Thor
    package_name "xbookmark"
    map %w[--version -v] => :version

    class_option :wiki, type: :string, desc: "Override the bookmark wiki path"
    class_option :vault, type: :string, desc: "Legacy alias for --wiki"
    class_option :verbose, type: :boolean, default: false, desc: "Verbose output"

    def self.exit_on_failure?
      true
    end

    desc "version", "Print xbookmark version"
    def version
      puts Xbookmark::VERSION
    end
  end
end

require_relative "cli/auth"
require_relative "cli/sync"
require_relative "cli/find"
require_relative "cli/doctor"
require_relative "cli/install"
require_relative "cli/setup"
require_relative "cli/uninstall"
require_relative "cli/taxonomy"

module Xbookmark
  class CLI
    desc "auth SUBCOMMAND ...ARGS", "Authenticate to X"
    subcommand "auth", Xbookmark::CLI::Auth

    desc "taxonomy SUBCOMMAND ...ARGS", "Audit and repair generated wiki taxonomy"
    subcommand "taxonomy", Xbookmark::CLI::Taxonomy

    desc "backfill [--limit N]", "Backfill X bookmarks. With --limit N performs a test backfill."
    method_option :limit, type: :numeric, desc: "Limit number of bookmarks (test backfill mode)"
    def backfill
      Xbookmark::CLI::Sync.new([], options).backfill_run
    end

    desc "sync", "Incremental sync of new X bookmarks"
    method_option :"from-scheduler", type: :boolean, default: false, desc: "Invoked from scheduler (skip-if-recent applies)"
    def sync
      Xbookmark::CLI::Sync.new([], options).sync_run
    end

    desc "import-birdclaw", "Import new bookmarks from an existing local Birdclaw archive (no X backfill)"
    method_option :db, type: :string, desc: "Birdclaw SQLite path (default ~/.birdclaw/birdclaw.sqlite)"
    method_option :limit, type: :numeric, desc: "Import at most N unseen bookmarks"
    def import_birdclaw
      Xbookmark::CLI::Sync.new([], options).birdclaw_import_run
    end

    desc "resync TWEET_ID", "Force re-enrichment of a single bookmark"
    def resync(tweet_id)
      Xbookmark::CLI::Sync.new([], options).resync_run(tweet_id)
    end

    desc "reenrich", "Offline re-enrichment of existing notes under the current contract (no X fetch)"
    method_option :limit, type: :numeric, desc: "Re-enrich at most N notes (resumable; omit for all)"
    method_option :model, type: :string,
                          desc: "Override the OpenRouter text model (defaults to DeepSeek V4 Flash Latest)"
    def reenrich
      Xbookmark::CLI::Sync.new([], options).reenrich_run
    end

    desc "find QUERY", "Search the bookmark wiki via QMD"
    method_option :limit, type: :numeric, default: 20
    def find(*query)
      if query.empty? || [%w[--help], %w[-h]].include?(query)
        self.class.command_help(shell, "find")
        return
      end

      Xbookmark::CLI::Find.new([], options).find_run(query.join(" "))
    end

    desc "doctor", "Check OpenRouter / whisper / qmd / X auth configuration"
    method_option :fix, type: :boolean, default: false, desc: "Prompt to run install commands for missing tools"
    def doctor
      Xbookmark::CLI::Doctor.new([], options).execute
    end

    desc "install", "Install the daily scheduler unit (systemd on Linux, launchd on macOS)"
    method_option :time, type: :string, desc: "HH:MM time of day (default 06:00)"
    method_option :"dry-run", type: :boolean, default: false
    method_option :uninstall, type: :boolean, default: false
    def install
      Xbookmark::CLI::Install.new([], options).execute
    end

    desc "setup", "Interactive first-run wizard (keystore + scheduler)"
    def setup
      Xbookmark::CLI::Setup.new([], options).execute
    end

    desc "uninstall", "Remove scheduler unit, keystore entries, and config dir (requires --purge)"
    method_option :purge, type: :boolean, default: false, desc: "Confirm full removal"
    method_option :yes, type: :boolean, default: false, desc: "Skip confirmation prompt"
    method_option :"dry-run", type: :boolean, default: false
    def uninstall
      code = Xbookmark::CLI::Uninstall.new([], options).execute
      exit(code) unless code == 0
    end
  end
end
