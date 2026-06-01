# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # End-to-end orchestrator for adding or replacing a project revision.
  # Pulls together the structured original data, the revision history, the
  # markdown renderer, and the post revisor. Returns a Result describing
  # success or the first validation failure encountered.
  #
  # On success, exactly one PostRevisor#revise! call happens; on failure,
  # neither the JSON history nor the post raw is mutated.
  class ProjectRevisionAdder
    MAX_NEW_ID_LENGTH = 64

    Result =
      Struct.new(:success, :error_key, :error_meta, :revision, keyword_init: true) do
        def success?
          success
        end
      end

    def self.call(topic:, user:, images:, mode: :add, note: nil)
      new(topic: topic, user: user, images: images, mode: mode, note: note).call
    end

    def initialize(topic:, user:, images:, mode:, note:)
      @topic = topic
      @user = user
      @input_images = Array(images)
      @mode = mode.to_sym
      @note = note.to_s.strip.presence
    end

    def call
      first_post = @topic.first_post
      return failure(:first_post_missing) if first_post.blank?

      reader = ProjectSubmissionReader.read(@topic)
      return failure(:project_data_invalid) unless reader.valid?

      raw = first_post.raw.to_s
      begin_marker = reader.begin_marker
      end_marker = reader.end_marker
      begin_offset = raw.index(begin_marker)
      end_offset = raw.index(end_marker)
      return failure(:project_markers_missing) if begin_offset.nil? || end_offset.nil?
      return failure(:project_markers_missing) if end_offset <= begin_offset

      built = build_image_records(reader)
      return built if built.is_a?(Result) # failure short-circuit

      # Mutate the JSON history first so the renderer sees the up-to-date
      # set. If the post update later fails we leak a saved JSON entry,
      # which is harmless data-wise (the renderer is called from history)
      # but matters as a known limitation — documented in COMPATIBILITY.md.
      history = ProjectRevisionHistory.for(@topic)
      return failure(:max_project_revisions_reached) if @mode == :add && history.at_max?
      return failure(:no_project_revision_to_replace) if @mode == :replace_latest && history.empty?

      entry =
        case @mode
        when :add
          history.add!(images: built, user: @user, note: @note)
        when :replace_latest
          history.replace_latest!(images: built, user: @user, note: @note)
        else
          return failure(:invalid_mode)
        end

      rendered =
        ProjectRevisionRenderer.render(
          original_data: reader_payload(reader),
          revisions: history.entries,
        )

      new_raw = splice_between_markers(raw, begin_marker, end_marker, rendered)

      fields = { raw: new_raw }
      fields[:title] = title_with_marker if title_with_marker

      revised =
        PostRevisor.new(first_post, @topic).revise!(
          @user,
          fields,
          skip_validations: true,
          bypass_bump: true,
          skip_revision: false,
        )

      return failure(:revision_failed) unless revised

      Result.new(success: true, error_key: nil, error_meta: nil, revision: entry)
    end

    private

    # Resolve each input image to a storage-shaped Hash, validating
    # uploads as we go. Returns the array OR a Result wrapping the first
    # validation failure.
    def build_image_records(reader)
      return failure(:images_required) if @input_images.empty?

      max_images = ProjectRevisionHistory.for(@topic).max_images
      return failure(:too_many_images, max: max_images) if @input_images.length > max_images

      seen_ids = {}
      prior_index = build_prior_index(reader)

      records =
        @input_images.map.with_index do |img, idx|
          hash = stringify_keys(img.respond_to?(:to_h) ? img.to_h : img)
          stable_id = hash["id"].to_s.strip
          stable_id = nil if stable_id.length > MAX_NEW_ID_LENGTH
          stable_id = SecureRandom.hex(8) if stable_id.blank?

          return failure(:duplicate_image_ids) if seen_ids.key?(stable_id)
          seen_ids[stable_id] = true

          upload_id = hash["upload_id"].to_i
          return failure(:invalid_image_payload) if upload_id <= 0

          upload = Upload.find_by(id: upload_id)
          return failure(:invalid_image_payload) if upload.blank?
          unless ImageUploadValidation.valid_image_upload?(upload)
            return failure(:invalid_image_payload)
          end

          {
            "id" => stable_id,
            "position" => idx + 1,
            "upload_id" => upload.id,
            "short_url" => upload.short_url,
            "caption" => hash["caption"].to_s,
            "alt" => "Image #{idx + 1}",
            "status" => status_for(prior_index, stable_id, upload.id),
          }
        end

      records
    end

    # Index prior version images by stable id so status_for can do
    # constant-time lookups. For add, prior version is the latest revision
    # (or original if none). For replace_latest, prior is the based_on of
    # the existing latest, so the status reflects "what changed since the
    # version this draft is based on" rather than churn against itself.
    def build_prior_index(reader)
      history = ProjectRevisionHistory.for(@topic)
      prior_images =
        if @mode == :replace_latest && history.latest
          base_number = history.latest["based_on"].to_i
          if base_number > 0
            base_rev = history.entries.find { |e| e["revision_number"].to_i == base_number }
            Array(base_rev && base_rev["images"])
          else
            Array(reader_payload(reader)["images"])
          end
        elsif history.latest
          Array(history.latest["images"])
        else
          Array(reader_payload(reader)["images"])
        end

      prior_images.each_with_object({}) { |img, acc| acc[img["id"].to_s] = img["upload_id"].to_i }
    end

    def status_for(prior_index, stable_id, upload_id)
      return "new" unless prior_index.key?(stable_id)
      prior_index[stable_id] == upload_id ? "unchanged" : "replaced"
    end

    def reader_payload(reader)
      { "type" => "project_critique", "version" => 1, "images" => reader.images }
    end

    # Replace exactly the slice between markers (markers themselves kept).
    # Anything outside the block — user-authored sections, signature, etc.
    # — round-trips byte-for-byte.
    def splice_between_markers(raw, begin_marker, end_marker, new_inner)
      begin_index = raw.index(begin_marker)
      end_index = raw.index(end_marker)
      head = raw[0...begin_index] + begin_marker
      tail = end_marker + raw[(end_index + end_marker.length)..]
      "#{head}\n\n#{new_inner.strip}\n\n#{tail}"
    end

    def title_with_marker
      return @title_with_marker if defined?(@title_with_marker)

      marker = SiteSetting.revised_critique_title_marker.to_s.strip
      current = @topic.title.to_s
      @title_with_marker =
        if marker.blank? || current.include?(marker)
          nil
        else
          candidate = "#{current} #{marker}".strip
          candidate.length <= SiteSetting.max_topic_title_length ? candidate : nil
        end
    end

    def stringify_keys(hash)
      return {} unless hash.is_a?(Hash) || hash.is_a?(ActionController::Parameters)
      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end

    def failure(key, meta = nil)
      Result.new(success: false, error_key: key, error_meta: meta, revision: nil)
    end
  end
end
