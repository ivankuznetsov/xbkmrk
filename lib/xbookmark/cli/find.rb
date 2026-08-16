# frozen_string_literal: true

require "thor"

module Xbookmark
  class CLI
    class Find < Thor::Group
      attr_reader :options

      def initialize(args = [], options = {}, _config = {})
        super
        @options = options
      end

      def find_run(query)
        require_relative "../config"
        require_relative "../qmd/searcher"

        config = Xbookmark::Config.load_offline(
          wiki_override: options[:wiki], vault_override: options[:vault], verbose: options[:verbose]
        )
        searcher = Xbookmark::Qmd::Searcher.new(config: config)
        hits = searcher.search(query, limit: options[:limit] || 20)
        if hits.empty?
          puts "No matches for: #{query}"
          return
        end
        hits.each_with_index do |hit, i|
          score = hit[:score] ? format("%.2f", hit[:score]) : "-"
          puts "#{i + 1}. [#{score}] #{hit[:path]}"
          puts "   #{hit[:snippet]}" if hit[:snippet]
        end
      end
    end
  end
end
