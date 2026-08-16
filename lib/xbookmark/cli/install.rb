# frozen_string_literal: true

require "thor"

module Xbookmark
  class CLI
    class Install < Thor::Group
      attr_reader :options

      def initialize(args = [], options = {}, _config = {})
        super
        @options = options
      end

      def execute
        require_relative "../config"
        require_relative "../scheduler/installer"
        require_relative "../qmd/registrar"

        config = Xbookmark::Config.load(wiki_override: options[:wiki], vault_override: options[:vault], verbose: options[:verbose])
        installer = Xbookmark::Scheduler::Installer.new(config: config)

        scheduler_options = {
          time: options[:time] || config.daily_sync_time,
          dry_run: options[:"dry-run"]
        }

        if options[:uninstall]
          installer.uninstall(**scheduler_options)
        else
          installer.install(**scheduler_options)
          unless options[:"dry-run"]
            registrar = Xbookmark::Qmd::Registrar.new(config: config)
            registrar.ensure_registered!
          end
        end
      end
    end
  end
end
