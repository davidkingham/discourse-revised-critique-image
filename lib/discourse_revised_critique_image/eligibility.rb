# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Centralises the rules that decide whether a given user can add a revised
  # image to a given topic. Used by both the controller (to authorise the
  # mutation) and the serializer (to drive whether the frontend button shows).
  class Eligibility
    Result = Struct.new(:ok, :error_key, keyword_init: true)

    def self.check(topic:, user:)
      new(topic: topic, user: user).check
    end

    def initialize(topic:, user:)
      @topic = topic
      @user = user
    end

    def check
      unless SiteSetting.revised_critique_enabled
        return failure(:plugin_disabled)
      end
      return failure(:not_owner) if @user.blank?
      if @user.respond_to?(:suspended?) && @user.suspended?
        return failure(:not_owner)
      end
      return failure(:not_owner) unless @topic.user_id == @user.id
      return failure(:not_in_category) unless in_configured_category?
      return failure(:cannot_edit_post) unless topic_editable?
      return failure(:cannot_edit_post) unless first_post_editable?
      return failure(:no_replies) if require_reply? && !has_other_user_reply?

      if has_existing_revision? && !SiteSetting.revised_critique_allow_replace
        return failure(:already_revised)
      end

      Result.new(ok: true)
    end

    def can_add?
      check.ok
    end

    private

    def in_configured_category?
      category_id = SiteSetting.revised_critique_category_id.to_i
      category_id > 0 && @topic.category_id == category_id
    end

    # Cheap topic-level checks. The strict `Guardian#can_edit?` check still
    # happens once more at the controller layer for defence in depth.
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

    def has_existing_revision?
      @topic.custom_fields[REVISED_IMAGE_UPLOAD_ID].present?
    end

    def failure(key)
      Result.new(ok: false, error_key: key)
    end
  end
end
