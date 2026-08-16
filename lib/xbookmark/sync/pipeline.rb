# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "../media/downloader"
require_relative "../transcribe/whisper"
require_relative "../enrich/orchestrator"
require_relative "../render/bookmark_renderer"
require_relative "../render/aux_page"
require_relative "../render/concept_page"
require_relative "../render/concept_index"
require_relative "../taxonomy/normalizer"
require_relative "../taxonomy/registry"
require_relative "thread_index"

module Xbookmark
  module Sync
    # Per-bookmark transactional pipeline:
    # 1. media download into scratch
    # 2. whisper transcription (best-effort; missing binary => transient)
    # 3. OpenRouter enrichment (external links -> final call)
    # 4. atomic move of media dir + atomic .md write
    # 5. ensure aux pages exist (after the bookmark write succeeds)
    class Pipeline
      Outcome = Struct.new(:status, :error, :markdown_path, :digest, :partial, keyword_init: true)

      def initialize(config:, store:, orchestrator:, renderer:, downloader: nil, whisper: nil,
                     registry: nil, thread_index: nil, defer_concept_index: false)
        @config = config
        @store = store
        @orch = orchestrator
        @renderer = renderer
        @downloader = downloader || Xbookmark::Media::Downloader.new
        @whisper = whisper || Xbookmark::Transcribe::Whisper.new(binary: config.whisper_bin, model: config.whisper_model)
        @registry = registry
        @thread_index = thread_index
        @defer_concept_index = defer_concept_index
        @concept_index_dirty = false
        @recurrence_counts = nil
      end

      def prepare_run!
        @registry = Xbookmark::Taxonomy::Registry.from_vault(@config.vault_path, store: @store)
        @thread_index = Xbookmark::Sync::ThreadIndex.new(store: @store)
        @concept_index_dirty = false
        @recurrence_counts = recurrence_counts_from_registry(@registry)
        @concept_references = Xbookmark::Render::ConceptPage.references_by_concept(
          vault_path: @config.vault_path,
          concepts: @registry.all
        )
      end

      def index_thread_bookmarks(bookmarks)
        current_thread_index.add_bookmarks(bookmarks)
      end

      def finalize_run!
        return unless @concept_index_dirty

        write_concept_index(current_registry.all)
        @concept_index_dirty = false
      end

      def process(bookmark)
        scratch = scratch_dir_for(bookmark)
        FileUtils.mkdir_p(scratch)
        guard(bookmark, scratch: scratch) do
          media_scratch = File.join(scratch, "media")
          media_records = bookmark.media.empty? ? [] : @downloader.download(bookmark.media, media_scratch)
          transcripts = transcribe_videos(media_records)
          # Move scratch media into the final bookmark wiki location.
          media_records = move_media_into_wiki(bookmark, media_records)
          enrich_render_persist(bookmark, transcripts: transcripts, image_paths: image_paths(media_records),
                                          media_records: media_records)
        end
      end

      # Re-render a bookmark from already-resolved inputs (NoteSource), skipping
      # media download, whisper, and the scratch→wiki media move. Writes in
      # place via existing_path so the note keeps its filename. vision carries
      # the captions a prior run produced so no fresh vision pass is needed.
      def process_offline(bookmark, transcripts:, image_paths:, media_records:, vision:, existing_path:)
        guard(bookmark, scratch: nil) do
          enrich_render_persist(bookmark, transcripts: transcripts, image_paths: image_paths,
                                          media_records: media_records, vision: vision, existing_path: existing_path)
        end
      end

      private

      # Shared enrich → normalize → render → persist tail for both the online
      # (process) and offline (process_offline) paths. existing_path, when
      # given, forces an in-place rewrite instead of a path lookup.
      def enrich_render_persist(bookmark, transcripts:, image_paths:, media_records:, vision: nil, existing_path: :lookup)
        registry = current_registry
        @orch.concept_registry = registry if @orch.respond_to?(:concept_registry=)
        @orch.existing_slugs = registry.all.map(&:slug) if @orch.respond_to?(:existing_slugs=)
        enrichment = @orch.enrich(bookmark, transcripts: transcripts, image_paths: image_paths, vision: vision)
        enrichment.concepts = normalize_concepts(enrichment.concepts, registry: registry)
        enrichment.concepts = reject_author_self_concepts(enrichment.concepts, bookmark)

        thread = current_thread_index.thread_for(bookmark)
        existing_path = @store.find_bookmark(bookmark.tweet_id)&.dig(:markdown_path) if existing_path == :lookup
        markdown = @renderer.render(bookmark, enrichment, media_records: media_records, transcripts: transcripts,
                                    link_blobs: Array(enrichment.link_blobs), thread: thread)
        markdown_path = @renderer.write(bookmark, markdown, enrichment: enrichment, existing_path: existing_path)
        digest = @renderer.digest(enrichment, bookmark)
        refresh_concept_references(markdown_path)

        ensure_aux_pages(bookmark, enrichment, thread: thread)
        Outcome.new(status: :done, markdown_path: markdown_path, digest: digest, partial: enrichment.partial?)
      end

      # Wrap an enrichment attempt with the shared error policy: transient
      # errors retry, everything else (including coding bugs) becomes permanent
      # rather than being silently retried against live APIs. Always clears the
      # scratch dir when one was allocated.
      def guard(bookmark, scratch:)
        yield.tap { FileUtils.rm_rf(scratch) if scratch }
      rescue Xbookmark::TransientError, Xbookmark::RateLimited => e
        # WhisperUnavailable, MediaError, and EnrichmentError already inherit
        # from TransientError — the rescue list above covers all of them.
        FileUtils.rm_rf(scratch) if scratch
        Outcome.new(status: :needs_retry, error: e)
      rescue Xbookmark::PermanentError => e
        FileUtils.rm_rf(scratch) if scratch
        Outcome.new(status: :permanent_error, error: e)
      rescue StandardError => e
        FileUtils.rm_rf(scratch) if scratch
        warn "[xbookmark] pipeline crashed for tweet #{bookmark.tweet_id}: #{e.class}: #{e.message}"
        warn e.backtrace.first(20).join("\n") if e.backtrace
        Outcome.new(status: :permanent_error, error: e)
      end

      def scratch_dir_for(bookmark)
        File.join(@config.scratch_dir, bookmark.tweet_id.to_s)
      end

      def transcribe_videos(media_records)
        out = {}
        media_records.each do |m|
          next unless m[:kind] == "video" || m[:kind] == "animated_gif"
          duration = m[:duration_ms]
          next if duration && duration < Xbookmark::Transcribe::Whisper::MIN_DURATION_MS
          text = @whisper.transcribe(m[:path], duration_ms: duration)
          out[File.basename(m[:path])] = text unless text.to_s.empty?
        end
        out
      end

      def image_paths(media_records)
        media_records.select { |m| m[:kind] == "photo" }.map { |m| m[:path] }
      end

      def move_media_into_wiki(bookmark, media_records)
        return media_records if media_records.empty?
        final_dir = @renderer.media_dir_for(bookmark)
        FileUtils.mkdir_p(File.dirname(final_dir))
        FileUtils.rm_rf(final_dir) if File.exist?(final_dir)
        # Move the parent media dir from scratch
        scratch_media = File.dirname(media_records.first[:path])
        File.rename(scratch_media, final_dir)
        media_records.map do |m|
          m.merge(path: File.join(final_dir, File.basename(m[:path])))
        end
      end

      def normalize_concepts(candidates, registry:)
        normalizer = Xbookmark::Taxonomy::Normalizer.new(
          registry: registry,
          recurrence_counts: recurrence_counts_for(candidates, registry: registry)
        )
        normalizer.normalize_candidates(candidates)
      end

      def reject_author_self_concepts(concepts, bookmark)
        author_slug = Xbookmark::Render::Wikilinks.slug(bookmark.author_handle)
        Array(concepts).reject { |concept| concept.slug == author_slug }
      end

      def ensure_aux_pages(bookmark, enrichment, thread:)
        aux_orchestrator = @config.respond_to?(:aux_summaries) && @config.aux_summaries ? @orch : nil
        author = Xbookmark::Render::Wikilinks.author_slug(bookmark.author_handle)
        author_page = Xbookmark::Render::AuthorPage.new(vault_path: @config.vault_path, store: @store, orchestrator: aux_orchestrator)
        snippet = bookmark.text.to_s
        author_page.ensure!(slug: author, label: "@#{bookmark.author_handle}", inputs: [snippet])

        concept_page = Xbookmark::Render::ConceptPage.new(vault_path: @config.vault_path, store: @store,
                                                          references: concept_references)
        Array(enrichment.concepts).each do |concept|
          # Each bookmark contributes one unit of evidence; the store
          # accumulates across bookmarks (see Store#upsert_concept).
          attrs = concept.to_h.transform_keys(&:to_sym)
          attrs[:evidence_count] = 1
          @store.upsert_concept(**attrs)
          persisted = Xbookmark::Taxonomy::Registry.concept_from_row(@store.find_concept(concept.slug))
          concept_page.ensure!(persisted)
          current_registry.add(persisted)
          @concept_index_dirty = true
        end
        write_concept_index(current_registry.all) unless @defer_concept_index || !@concept_index_dirty

        if thread
          thread_page = Xbookmark::Render::ThreadPage.new(vault_path: @config.vault_path, store: @store, orchestrator: @orch)
          thread_page.ensure!(slug: thread[:slug], label: thread[:label], inputs: [snippet])
        end
      end

      def current_registry
        @registry ||= Xbookmark::Taxonomy::Registry.from_vault(@config.vault_path, store: @store).tap do |registry|
          @recurrence_counts ||= recurrence_counts_from_registry(registry)
        end
      end

      def concept_references
        @concept_references ||= Xbookmark::Render::ConceptPage.references_by_concept(
          vault_path: @config.vault_path,
          concepts: current_registry.all
        )
      end

      def refresh_concept_references(markdown_path)
        Xbookmark::Render::ConceptPage.add_note_references!(
          concept_references,
          markdown_path,
          vault_path: @config.vault_path
        )
      end

      def current_thread_index
        @thread_index ||= Xbookmark::Sync::ThreadIndex.new(store: @store)
      end

      def recurrence_counts_for(candidates, registry:)
        normalizer = Xbookmark::Taxonomy::Normalizer.new(registry: registry)
        counts = @recurrence_counts ||= recurrence_counts_from_registry(registry)
        Array(candidates).each do |candidate|
          label =
            if candidate.is_a?(Hash)
              candidate["label"] || candidate[:label] || candidate["slug"] || candidate[:slug]
            else
              candidate
            end
          counts[normalizer.canonical_slug(label)] += 1
        end
        counts.dup
      end

      def recurrence_counts_from_registry(registry)
        registry.all.each_with_object(Hash.new(0)) do |concept, counts|
          counts[concept.slug] += concept.evidence_count.to_i
        end
      end

      def write_concept_index(concepts)
        conflicts = concepts.count { |concept| !concept.canonical? }
        Xbookmark::Render::ConceptIndex.new(vault_path: @config.vault_path).write(concepts, conflicts: conflicts)
        @concept_index_dirty = false
      end
    end
  end
end
