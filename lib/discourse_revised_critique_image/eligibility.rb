# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Centralises the rules that decide whether a given user can add or replace
  # a revised image on a given topic. Used by both the controller (to
  # authorise the mutation) and the serializer (to drive whether the frontend
  # buttons are shown).
  class Eligibility
    MODES = %i[add replace_latest].freeze

    # Tag name used by the submissions plugin (and by hand-curation on
    # legacy topics) to mark a topic as belonging to the project critique
    # flow. The single-image revision flow refuses any topic carrying it,
    # even if structured project data is missing or malformed — the tag
    # alone is treated as a strong "do not touch the first post" signal.
    PROJECT_TAG_NAME = "project"
    PROJECT_SUBMISSION_TYPE = "project_critique"

    Result = Struct.new(:ok, :error_key, keyword_init: true)

    def self.check(topic:, user:, mode: :add)
      new(topic: topic, user: user, mode: mode).check
    end

    def initialize(topic:, user:, mode: :add)
      @topic = topic
      @user = user
      @mode = mode.to_sym
    end

    def check
      return failure(:invalid_mode) if MODES.exclude?(@mode)
      return failure(:plugin_disabled) unless SiteSetting.revised_critique_enabled
      return failure(:not_owner) if @user.blank?
      return failure(:not_owner) if @user.respond_to?(:suspended?) && @user.suspended?
      return failure(:not_owner) unless @topic.user_id == @user.id
      return failure(:not_in_category) unless in_configured_category?
      # Defensive gate: a project-critique topic from discourse-npn-submissions
      # carries a structured payload (and post-body markers) that the
      # single-image flow would corrupt by rewriting the first post. Refuse
      # both add and replace_latest until the project revision editor lands.
      return failure(:project_topic_unsupported) if project_topic?
      return failure(:cannot_edit_post) unless topic_editable?
      return failure(:cannot_edit_post) unless first_post_editable?
      return failure(:no_replies) if require_reply? && !has_other_user_reply?

      case @mode
      when :add
        return failure(:max_revisions_reached) if history.at_max?
      when :replace_latest
        return failure(:no_revision_to_replace) if history.empty?
      end

      Result.new(ok: true)
    end

    def can?
      check.ok
    end

    private

    def history
      @history ||= RevisionHistory.for(@topic)
    end

    def in_configured_category?
      category_id = SiteSetting.revised_critique_category_id.to_i
      category_id > 0 && @topic.category_id == category_id
    end

    def topic_editable?
      return false if @topic.closed?
      return false if @topic.archived?
      return false if @topic.deleted_at.present?
      true
    end

    def first_post_editable?
      first_post = @topic.first_post
      return false if first_post.blank?
      return false if first_post.deleted_at.present?
      Guardian.new(@user).can_edit?(first_post)
    end

    def require_reply?
      SiteSetting.revised_critique_require_reply_from_other_user
    end

    def has_other_user_reply?
      Post
        .where(topic_id: @topic.id, deleted_at: nil)
        .where("post_number > 1")
        .where("user_id <> ?", @topic.user_id)
        .exists?
    end

    # Tiered project-signal check. Each probe runs independently with
    # its own narrow rescue so a failure in one source can never bypass
    # the others. Any positive signal blocks; only the absence of all
    # signals lets the single-image flow proceed.
    #
    # Cheapest signals run first (tag check + raw custom_field read) so
    # an obvious project topic doesn't pay the cost of building a
    # ProjectSubmissionReader::Result. Crucially, this means that even
    # if the reader raises or returns invalid for a malformed payload,
    # a topic tagged "project" or flagged via npn_submission_type still
    # gets blocked.
    def project_topic?
      project_tag_present? || project_submission_type_set? || reader_says_project?
    end

    def project_tag_present?
      return false unless @topic.respond_to?(:tags)
      @topic.tags.exists?(name: PROJECT_TAG_NAME)
    rescue => e
      log_probe_failure(:tag, e)
      false
    end

    def project_submission_type_set?
      key = SubmissionsCompat.submission_type_key
      @topic.custom_fields[key].to_s == PROJECT_SUBMISSION_TYPE
    rescue => e
      log_probe_failure(:submission_type, e)
      false
    end

    def reader_says_project?
      ProjectSubmissionReader.read(@topic).project?
    rescue => e
      log_probe_failure(:reader, e)
      false
    end

    def log_probe_failure(probe, error)
      Rails.logger.warn(
        "discourse-revised-critique-image: #{probe} project probe raised for " \
          "topic #{@topic&.id}: #{error.class}: #{error.message}",
      )
    end

    def failure(key)
      Result.new(ok: false, error_key: key)
    end
  end
end
