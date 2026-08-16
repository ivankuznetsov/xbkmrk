# frozen_string_literal: true

require "json"
require_relative "normalizer"
require_relative "prompt_context"
require_relative "registry"
require_relative "states"

module Xbookmark
  module Taxonomy
    # Deterministic taxonomy curation layer. `curate` normalizes candidates,
    # gates low-confidence concepts as blocked conflicts, and (when a store is
    # given) persists both the concept row and an audit entry in
    # `curator_decisions`. Scheduled maintenance may provide an LLM client for
    # LLM curation; when that runner is unavailable or returns invalid output,
    # this falls back to deterministic normalization so local maintenance still
    # progresses offline.
    class Curator
      MIN_CONFIDENCE = 0.3
      DECISION_SCHEMA = {
        "type" => "object",
        "required" => %w[decisions],
        "properties" => {
          "decisions" => {
            "type" => "array",
            "items" => {
              "type" => "object",
              "properties" => {
                "slug" => { "type" => "string" },
                "label" => { "type" => "string" },
                "kind" => { "type" => "string" },
                "aliases" => { "type" => "array", "items" => { "type" => "string" } },
                "broader" => { "type" => "array", "items" => { "type" => "string" } },
                "facets" => { "type" => "array", "items" => { "type" => "string" } },
                "evidence_count" => { "type" => "integer" },
                "confidence" => { "type" => "number" },
                "curation_state" => { "type" => "string" }
              }
            }
          }
        }
      }.freeze

      def initialize(llm: nil, codex: nil, registry: Registry.new, normalizer: nil, store: nil, timeout: nil)
        @llm = llm || codex
        @registry = registry
        @normalizer = normalizer || Normalizer.new(registry: registry)
        @store = store
        @timeout = timeout
      end

      def curate(candidates)
        decisions = llm_decisions(candidates) || deterministic_decisions(candidates)
        persist_decisions(decisions)
        decisions
      end

      def prompt_for(candidates)
        labels = Array(candidates).map { |candidate| candidate.is_a?(Hash) ? candidate["label"] || candidate[:label] : candidate }
        context = PromptContext.new(registry: @registry).to_json_for(labels)
        <<~PROMPT
          Resolve taxonomy candidates using only this sanitized registry context.
          Prefer broad parent concepts with child concepts through `broader`, not separate flat duplicates.
          Return JSON with a `decisions` array.

          Candidates:
          #{JSON.generate(Array(candidates))}

          Sanitized registry context:
          #{context}
        PROMPT
      end

      private

      # Persist the whole batch atomically when the store supports a
      # transaction, so a failure partway through the batch (a bad row, a DB
      # error) rolls back every concept write from this curation pass rather
      # than leaving orphan concept/curator_decision rows that diverge from the
      # generated files. Curation is a pure-DB phase, so a transaction gives
      # true all-or-nothing semantics here.
      def persist_decisions(decisions)
        if @store.respond_to?(:transaction)
          @store.transaction { decisions.each { |decision| persist(decision) } }
        else
          decisions.each { |decision| persist(decision) }
        end
      end

      def deterministic_decisions(candidates)
        concepts = @normalizer.normalize_candidates(candidates)
        concepts.map { |concept| decision_for(concept) }
      end

      def llm_decisions(candidates)
        return nil unless @llm

        kwargs = { prompt: prompt_for(candidates), json_schema: DECISION_SCHEMA }
        kwargs[:timeout] = @timeout if @timeout
        response = @llm.run(**kwargs)
        decisions = Array(response["decisions"]).filter_map { |decision| decision_from_llm(decision) }
        decisions.empty? ? nil : decisions
      rescue StandardError => e
        warn "[xbookmark] taxonomy curator fell back to deterministic rules: #{e.class}: #{e.message}"
        nil
      end

      def decision_from_llm(value)
        return nil unless value.is_a?(Hash)

        raw_slug = value["slug"] || value[:slug] || value["label"] || value[:label]
        return nil if raw_slug.to_s.strip.empty?

        slug = @normalizer.canonical_slug(raw_slug)

        concept = Concept.new(
          slug: slug,
          label: value["label"] || value[:label],
          kind: value["kind"] || value[:kind] || Concept::DEFAULT_KIND,
          aliases: value["aliases"] || value[:aliases] || [],
          broader: value["broader"] || value[:broader] || [],
          facets: value["facets"] || value[:facets] || [],
          evidence_count: value["evidence_count"] || value[:evidence_count] || 1,
          confidence: value["confidence"] || value[:confidence],
          outcome: value["curation_state"] || value[:curation_state] ||
            value["curator_outcome"] || value[:curator_outcome] || Concept::DEFAULT_OUTCOME
        )
        decision_for(concept)
      end

      def decision_for(concept)
        state = concept.confidence < MIN_CONFIDENCE ? States::BLOCKED_CONFLICTS : concept.outcome
        concept.to_h.merge("curation_state" => state)
      end

      # Persistence is optional: `curate` always returns the decisions, and the
      # store write only runs when a store was provided. The audit log entry
      # keeps blocked-conflict decisions inspectable rather than discarding them.
      def persist(decision)
        return unless @store

        existing = @store.respond_to?(:find_concept) && @store.find_concept(decision["slug"])
        @store.upsert_concept(
          slug: decision["slug"],
          label: decision["label"],
          kind: decision["kind"],
          aliases: decision["aliases"],
          broader: decision["broader"],
          facets: decision["facets"],
          evidence_count: existing ? 0 : decision["evidence_count"],
          confidence: decision["confidence"],
          curator_outcome: decision["curation_state"]
        )
        @store.record_curator_decision(slug: decision["slug"], decision: decision)
      end
    end
  end
end
