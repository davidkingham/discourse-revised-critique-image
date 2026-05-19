# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Edits the raw markdown of a topic's first post to insert a "Revised Version"
  # block at the top, optionally appends a configurable title marker, and
  # records the revision on the topic's custom fields.
  class RevisionAdder
    BEGIN_MARKER = "<!-- revised-critique-image:begin -->"
    END_MARKER = "<!-- revised-critique-image:end -->"

    Result =
      Struct.new(:success, :error_key, :error_message, keyword_init: true)

    def self.call(topic:, upload:, user:, note: nil)
      new(topic: topic, upload: upload, user: user, note: note).call
    end

    def initialize(topic:, upload:, user:, note: nil)
      @topic = topic
      @upload = upload
      @user = user
      @note = note.to_s.strip.presence
    end

    def call
      first_post = @topic.first_post
      return failure(:first_post_missing) if first_post.blank?

      new_raw = build_new_raw(first_post.raw)
      fields = { raw: new_raw }
      fields[:title] = title_with_marker if title_with_marker

      revisor = PostRevisor.new(first_post, @topic)
      # skip_validations: the OP may legitimately have a short raw body (e.g.
      # just an image with no text), which would otherwise trip min-body-length
      # validations on edit. Permissions are already enforced by Eligibility
      # and (defence-in-depth) by `Guardian#can_edit?` in the controller.
      saved =
        revisor.revise!(
          @user,
          fields,
          skip_validations: true,
          bypass_bump: true,
          skip_revision: false
        )
      return failure(:revision_failed) unless saved

      persist_custom_fields!
      maybe_post_notice_reply!

      Result.new(success: true)
    end

    private

    def build_new_raw(existing_raw)
      stripped = strip_existing_block(existing_raw)
      "#{revision_block}\n\n## #{original_heading}\n\n#{stripped}"
    end

    def strip_existing_block(raw)
      return raw if raw.exclude?(BEGIN_MARKER) || raw.exclude?(END_MARKER)

      pattern =
        /#{Regexp.escape(BEGIN_MARKER)}.*?#{Regexp.escape(END_MARKER)}\s*/m
      cleaned = raw.sub(pattern, "")
      # Also remove a stale "## Original Version" heading we previously inserted.
      cleaned.sub(/\A## #{Regexp.escape(original_heading)}\s*\n+/, "")
    end

    def revision_block
      lines = [BEGIN_MARKER, "## #{revised_heading}", "", image_markdown]
      lines += ["", "**#{what_changed_label}** #{escape_note(@note)}"] if @note
      lines += ["", "*#{notice_text}*", "", "---", END_MARKER]
      lines.join("\n")
    end

    def image_markdown
      "![Revised version|#{upload_dimensions}](#{@upload.short_url})"
    end

    def upload_dimensions
      width = @upload.width.to_i
      height = @upload.height.to_i
      return "690x460" if width <= 0 || height <= 0
      "#{width}x#{height}"
    end

    # Collapse multi-line input to single-line for the inline "What changed"
    # paragraph. Discourse markdown sanitises output; we only normalise
    # whitespace so the inline rendering stays predictable.
    def escape_note(note)
      note.gsub(/\s*\r?\n+\s*/, " ").strip
    end

    def revised_heading
      SiteSetting.revised_critique_heading.presence ||
        I18n.t("discourse_revised_critique_image.revised_heading")
    end

    def original_heading
      I18n.t("discourse_revised_critique_image.original_heading")
    end

    def notice_text
      I18n.t("discourse_revised_critique_image.revision_notice")
    end

    def what_changed_label
      I18n.t("discourse_revised_critique_image.what_changed_label")
    end

    # Returns the new title to use, or nil if no change is needed (either the
    # marker is disabled, already present, or would push the title past the
    # max length — in which case we skip the title update rather than fail
    # the whole revision).
    def title_with_marker
      return @title_with_marker if defined?(@title_with_marker)

      marker = SiteSetting.revised_critique_title_marker.to_s.strip
      current = @topic.title.to_s
      @title_with_marker =
        if marker.blank? || current.include?(marker)
          nil
        else
          candidate = "#{current} #{marker}".strip
          if candidate.length <= SiteSetting.max_topic_title_length
            candidate
          else
            nil
          end
        end
    end

    def persist_custom_fields!
      @topic.custom_fields[REVISED_IMAGE_UPLOAD_ID] = @upload.id
      @topic.custom_fields[REVISED_IMAGE_ADDED_AT] = Time.zone.now.iso8601
      @topic.custom_fields[REVISED_IMAGE_ADDED_BY_USER_ID] = @user.id
      @topic.custom_fields[REVISED_IMAGE_NOTE] = @note
      @topic.save_custom_fields(true)
    end

    def maybe_post_notice_reply!
      return unless SiteSetting.revised_critique_add_notice_reply

      PostCreator.create!(
        notice_reply_user,
        topic_id: @topic.id,
        raw: I18n.t("discourse_revised_critique_image.notice_reply"),
        skip_validations: true
      )
    end

    def notice_reply_user
      username = SiteSetting.revised_critique_notice_reply_username.to_s.strip
      return Discourse.system_user if username.blank? || username == "system"

      User.find_by_username(username) || Discourse.system_user
    end

    def failure(key)
      Result.new(success: false, error_key: key)
    end
  end
end
