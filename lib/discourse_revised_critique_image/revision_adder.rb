# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Adds or replaces a revision on a topic, rewriting the markdown block
  # in the first post and persisting the JSON revision history.
  class RevisionAdder
    BEGIN_MARKER = "<!-- revised-critique-image:begin -->"
    END_MARKER = "<!-- revised-critique-image:end -->"

    Result = Struct.new(:success, :error_key, :error_message, keyword_init: true)

    def self.call(topic:, upload:, user:, note: nil, mode: :add)
      new(topic: topic, upload: upload, user: user, note: note, mode: mode).call
    end

    def initialize(topic:, upload:, user:, note: nil, mode: :add)
      @topic = topic
      @upload = upload
      @user = user
      @note = note.to_s.strip.presence
      @mode = mode.to_sym
    end

    def call
      first_post = @topic.first_post
      return failure(:first_post_missing) if first_post.blank?

      # Wrap the JSON history mutation and the PostRevisor edit in a
      # single Topic.transaction so a revise! refusal (returns false) or
      # exception rolls back BOTH. Pre-Phase-3-hardening, a returns-false
      # would leave the topic carrying revision custom_fields the post
      # body never received — a phantom revision visible to serializers
      # but missing from the actual rendered post.
      #
      # Trade-offs are identical to ProjectRevisionAdder: Sidekiq jobs
      # enqueued from after_save (rather than after_commit) callbacks
      # would still fire even on rollback. Discourse's first-party
      # post-edit callbacks are after_commit, so the corner case is
      # narrow and was already present before this commit.
      #
      # maybe_post_notice_reply! stays OUTSIDE the transaction: the notice
      # is a separate post unrelated to the revision storage, and we want
      # a notice-creation failure to bubble after the revision is durably
      # saved rather than unwinding the (otherwise successful) revision.
      saved = false

      Topic.transaction do
        apply_history_change!

        new_raw = build_new_raw(first_post.raw)
        fields = { raw: new_raw }
        fields[:title] = title_with_marker if title_with_marker

        # skip_validations: the OP may legitimately have a short raw body
        # (e.g. just an image with no text), which would otherwise trip
        # min-body-length validations on edit. Permissions are already
        # enforced by Eligibility and (defence-in-depth) by
        # `Guardian#can_edit?` in the controller.
        saved =
          PostRevisor.new(first_post, @topic).revise!(
            @user,
            fields,
            skip_validations: true,
            bypass_bump: true,
            skip_revision: false,
          )

        raise ActiveRecord::Rollback unless saved
      end

      return failure(:revision_failed) unless saved

      maybe_post_notice_reply!

      Result.new(success: true)
    end

    private

    def history
      @history ||= RevisionHistory.for(@topic)
    end

    # Mutate the JSON history first so build_new_raw renders the up-to-date set.
    # Persist (and sync the denormalised "latest" scalar fields) atomically
    # alongside the raw/title revision below.
    def apply_history_change!
      case @mode
      when :add
        history.add!(upload: @upload, user: @user, note: @note)
      when :replace_latest
        history.replace_latest!(upload: @upload, user: @user, note: @note)
      end
    end

    def build_new_raw(existing_raw)
      stripped = strip_existing_block(existing_raw)
      "#{revision_block}\n\n## #{original_heading}\n\n#{stripped}"
    end

    def strip_existing_block(raw)
      return raw if raw.exclude?(BEGIN_MARKER) || raw.exclude?(END_MARKER)

      pattern = /#{Regexp.escape(BEGIN_MARKER)}.*?#{Regexp.escape(END_MARKER)}\s*/m
      cleaned = raw.sub(pattern, "")
      cleaned.sub(/\A## #{Regexp.escape(original_heading)}\s*\n+/, "")
    end

    # The full block contains every revision in the history, newest first.
    def revision_block
      lines = [BEGIN_MARKER, "## #{revised_heading}"]
      ordered = history.entries.reverse
      ordered.each_with_index do |entry, index|
        lines << ""
        lines << "### #{label_for(entry, latest: index.zero?)}"
        lines << ""
        lines << image_markdown(entry)
        if entry["note"].present?
          lines << ""
          lines << "**#{what_changed_label}** #{escape_note(entry["note"])}"
        end
      end
      lines << ""
      lines << "*#{notice_text}*"
      lines << ""
      lines << "---"
      lines << END_MARKER
      lines.join("\n")
    end

    def label_for(entry, latest:)
      key = latest ? "latest_revision_label" : "previous_revision_label"
      I18n.t("discourse_revised_critique_image.#{key}", number: entry["revision_number"])
    end

    def image_markdown(entry)
      "![Revised version|#{dimensions_for(entry)}](#{entry["upload_short_url"]})"
    end

    def dimensions_for(entry)
      width = entry["width"].to_i
      height = entry["height"].to_i
      return "690x460" if width <= 0 || height <= 0
      "#{width}x#{height}"
    end

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

    def maybe_post_notice_reply!
      return unless SiteSetting.revised_critique_add_notice_reply

      PostCreator.create!(
        notice_reply_user,
        topic_id: @topic.id,
        raw: I18n.t("discourse_revised_critique_image.notice_reply"),
        skip_validations: true,
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
