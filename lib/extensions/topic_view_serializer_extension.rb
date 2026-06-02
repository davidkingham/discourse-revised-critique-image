# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  module TopicViewSerializerExtension
    def self.prepended(base)
      base.attributes :revised_critique_image,
                      :revised_critique_image_revision_count,
                      :revised_critique_image_max_revisions,
                      :can_add_revised_critique_image,
                      :can_replace_latest_revised_critique_image,
                      :revised_critique_revision_type,
                      :revised_critique_project_detected,
                      :revised_critique_project_valid,
                      :revised_critique_project_image_count,
                      :revised_critique_project_error_key,
                      :project_revision_count,
                      :project_revision_max_revisions,
                      :project_revision_max_images,
                      :can_add_project_revision,
                      :can_replace_latest_project_revision,
                      :project_revision_editor
    end

    def revised_critique_image
      latest = history.latest
      return nil if latest.blank?

      {
        revision_number: latest["revision_number"],
        upload_id: latest["upload_id"],
        added_at: latest["created_at"],
        updated_at: latest["updated_at"],
        added_by_user_id: latest["user_id"],
        note: latest["note"],
      }
    end

    def revised_critique_image_revision_count
      history.count
    end

    def revised_critique_image_max_revisions
      history.max
    end

    def can_add_revised_critique_image
      return false if scope&.user.blank?
      Eligibility.check(topic: object.topic, user: scope.user, mode: :add).ok
    end

    def can_replace_latest_revised_critique_image
      return false if scope&.user.blank?
      Eligibility.check(topic: object.topic, user: scope.user, mode: :replace_latest).ok
    end

    # ---- Phase 2: project critique handoff (read-only) -------------------
    # These attributes let the frontend tell whether a topic was created
    # by discourse-npn-submissions' project flow, and whether the
    # structured payload is in a shape a future project-revision editor
    # could safely consume. They never mutate anything.

    def revised_critique_revision_type
      project_reader_result.project? ? "project" : "single_image"
    end

    def revised_critique_project_detected
      project_reader_result.project?
    end

    def revised_critique_project_valid
      project_reader_result.valid?
    end

    def revised_critique_project_image_count
      project_reader_result.image_count
    end

    # Surfaced only for staff so admins can diagnose handoff problems on
    # production topics without exposing internal error key vocabulary to
    # normal users.
    def revised_critique_project_error_key
      return nil unless scope&.user&.staff?
      project_reader_result.error_key&.to_s
    end

    # ---- Phase 3: project revision flow ---------------------------------
    # Read-only state for any UI that wants to know whether the project
    # editor can be reached and how many revisions already exist. Mirrors
    # the single-image attribute set (revision_count + can_* booleans).

    def project_revision_count
      project_history.count
    end

    def project_revision_max_revisions
      project_history.max
    end

    def project_revision_max_images
      project_history.max_images
    end

    def can_add_project_revision
      return false if scope&.user.blank?
      ProjectEligibility.check(topic: object.topic, user: scope.user, mode: :add).ok
    end

    def can_replace_latest_project_revision
      return false if scope&.user.blank?
      ProjectEligibility.check(topic: object.topic, user: scope.user, mode: :replace_latest).ok
    end

    # Per-viewer baseline payload the project editor loads on open.
    # Only emitted when the viewer can actually use the editor (OP or
    # staff with edit rights), so normal members never receive the
    # full image+URL data.
    #
    # Shape:
    #   {
    #     "original" => { "images" => [...], "note" => "" }  (when project detected + valid)
    #     "latest"   => { "images" => [...], "note" => "..." } (when at least one revision exists)
    #   }
    #
    # `images` entries include `image_url` so the editor can display
    # thumbnails without a second round-trip; `short_url` is also
    # included so the save payload doesn't need to re-resolve uploads.
    def project_revision_editor
      return nil unless can_use_editor?

      payload = {}
      reader = project_reader_result
      if reader.project? && reader.valid?
        payload["original"] = build_editor_payload(reader.images, note: nil)
      end

      latest = project_history.latest
      payload["latest"] = build_editor_payload(latest["images"], note: latest["note"]) if latest

      payload
    end

    private

    def history
      @_revised_critique_history ||= RevisionHistory.for(object.topic)
    end

    def project_history
      @_project_revision_history ||= ProjectRevisionHistory.for(object.topic)
    end

    def can_use_editor?
      return false if scope&.user.blank?
      can_add_project_revision || can_replace_latest_project_revision
    end

    def build_editor_payload(images, note:)
      images = Array(images)
      upload_ids = images.map { |i| i["upload_id"].to_i }.compact.uniq
      uploads = upload_ids.any? ? Upload.where(id: upload_ids).index_by(&:id) : {}

      {
        "images" =>
          images.map do |i|
            upload = uploads[i["upload_id"].to_i]
            {
              "id" => i["id"],
              "upload_id" => i["upload_id"],
              "short_url" => i["short_url"],
              "image_url" => upload&.url,
              "caption" => i["caption"].to_s,
              "alt" => i["alt"],
            }
          end,
        "note" => note.to_s,
      }
    end

    # Compute once per serializer instance. Wrapped in a rescue so a bug
    # in the reader (or a sibling-plugin API drift) can't take down topic
    # rendering — the topic still serializes, just with the Phase 2
    # attributes reporting "not a project topic".
    def project_reader_result
      @_project_reader_result ||=
        begin
          ProjectSubmissionReader.read(object.topic)
        rescue => e
          Rails.logger.warn(
            "discourse-revised-critique-image: ProjectSubmissionReader " \
              "raised for topic #{object.topic&.id}: #{e.class}: #{e.message}",
          )
          ProjectSubmissionReader::Result.new(
            project?: false,
            valid?: false,
            error_key: :reader_raised,
            images: [],
            image_count: 0,
            begin_offset: nil,
            end_offset: nil,
            begin_marker: nil,
            end_marker: nil,
          )
        end
    end
  end
end
