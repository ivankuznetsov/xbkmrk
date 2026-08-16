# frozen_string_literal: true

require "thor"

module Xbookmark
  class CLI
    class Sync < Thor::Group
      include Thor::Actions

      attr_reader :options

      def initialize(args = [], options = {}, _config = {})
        super
        @options = options
      end

      def backfill_run
        require_relative "../config"
        require_relative "../sync/runner"
        require_relative "../state/store"
        require_relative "../x/auth"
        require_relative "../x/client"

        config = Xbookmark::Config.load(wiki_override: options[:wiki], vault_override: options[:vault], verbose: options[:verbose])
        store  = Xbookmark::State::Store.new(config.state_db_path)
        client = Xbookmark::X::Client.new(config: config, store: store)
        runner = Xbookmark::Sync::Runner.new(config: config, store: store, x_client: client)

        mode  = options[:limit] ? :backfill_limited : :backfill_full
        report = runner.run(mode: mode, limit: options[:limit])
        puts report
        exit_with(report)
      end

      def sync_run
        require_relative "../config"
        require_relative "../sync/runner"
        require_relative "../state/store"
        require_relative "../x/client"

        config = Xbookmark::Config.load(wiki_override: options[:wiki], vault_override: options[:vault], verbose: options[:verbose])
        store  = Xbookmark::State::Store.new(config.state_db_path)
        client = Xbookmark::X::Client.new(config: config, store: store)
        runner = Xbookmark::Sync::Runner.new(config: config, store: store, x_client: client)

        report = runner.run(mode: :sync, from_scheduler: options[:"from-scheduler"])
        puts report
        exit_with(report)
      end

      def resync_run(tweet_id)
        require_relative "../config"
        require_relative "../sync/runner"
        require_relative "../state/store"
        require_relative "../x/client"

        config = Xbookmark::Config.load(wiki_override: options[:wiki], vault_override: options[:vault], verbose: options[:verbose])
        store  = Xbookmark::State::Store.new(config.state_db_path)
        client = Xbookmark::X::Client.new(config: config, store: store)
        runner = Xbookmark::Sync::Runner.new(config: config, store: store, x_client: client)

        report = runner.run(mode: :resync, tweet_id: tweet_id)
        puts report
        exit_with(report)
      end

      # Offline: re-runs the current enrichment contract over notes already in
      # the wiki (no X fetch). Reads config without X auth.
      def reenrich_run
        require_relative "../config"
        require_relative "../sync/reenricher"
        require_relative "../state/store"

        config = Xbookmark::Config.load_offline(wiki_override: options[:wiki], vault_override: options[:vault], verbose: options[:verbose])
        store  = Xbookmark::State::Store.new(config.state_db_path)

        report = Xbookmark::Sync::Reenricher.new(config: config, store: store, model: options[:model]).call(limit: options[:limit])
        exit(report.exit_code) unless report.exit_code.zero?
      end

      # Imports already archived Birdclaw rows. This path never constructs an
      # X client and is idempotent by tweet ID, so reruns are update-only.
      def birdclaw_import_run
        require_relative "../config"
        require_relative "../birdclaw/source"
        require_relative "../birdclaw/importer"
        require_relative "../state/store"

        config = Xbookmark::Config.load_offline(wiki_override: options[:wiki], vault_override: options[:vault], verbose: options[:verbose])
        store = Xbookmark::State::Store.new(config.state_db_path)
        source = Xbookmark::Birdclaw::Source.new(options[:db] || config.birdclaw_db_path)
        report = Xbookmark::Birdclaw::Importer.new(config: config, store: store, source: source).call(limit: options[:limit])
        exit(report.exit_code) unless report.exit_code.zero?
      end

      private

      def exit_with(report)
        maintenance_errors = report.respond_to?(:maintenance_errors) ? report.maintenance_errors : 0
        return if report.failed.zero? && report.permanent_errors.zero? && report.source_errors.zero? && maintenance_errors.zero?
        # An unattended scheduled run is best-effort: tolerate retryable trouble
        # (X source outages AND transient enrichment failures, both of which
        # auto-retry next run) so the timer doesn't report "failed" for things
        # that heal themselves. Only genuine dead-ends — permanent errors and
        # destructive maintenance failures — fail a scheduled run.
        return if options[:"from-scheduler"] && report.permanent_errors.zero? && maintenance_errors.zero?

        # Permanent errors → user error (1); transient retry → transient (2).
        exit(report.permanent_errors.positive? || report.source_errors.positive? || maintenance_errors.positive? ? 1 : 2)
      end
    end
  end
end
