# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  class RevisionsController < ::ApplicationController
    requires_plugin DiscourseRevisedCritiqueImage::PLUGIN_NAME

    # Conservative per-user limit. Sufficient for legitimate revising and
    # re-revising; tight enough to block obvious abuse. Staff bypass below.
    RATE_LIMIT_MAX = 6
    RATE_LIMIT_PERIOD = 1.hour

    before_action :ensure_logged_in

    def create
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::NotFound if topic.blank?
      raise Discourse::NotFound unless guardian.can_see?(topic)

      eligibility = Eligibility.check(topic: topic, user: current_user)
      return render_eligibility_error(eligibility) unless eligibility.ok

      # Defence in depth: even if Eligibility passed, re-check the strict
      # Guardian edit permission against the first post (covers post edit-time
      # limit, plugin guardian overrides, etc.).
      first_post = topic.first_post
      unless first_post && guardian.can_edit?(first_post)
        return render_plugin_error(:cannot_edit_post, 403)
      end

      upload = Upload.find_by(id: params[:upload_id])
      return render_plugin_error(:missing_upload, 404) if upload.blank?
      unless valid_image_upload?(upload)
        return render_plugin_error(:invalid_upload, 422)
      end

      note = params[:note].to_s.strip
      max = SiteSetting.revised_critique_note_max_length.to_i
      if max > 0 && note.length > max
        return render_plugin_error(:note_too_long, 422)
      end

      apply_rate_limit!

      result =
        RevisionAdder.call(
          topic: topic,
          upload: upload,
          user: current_user,
          note: note
        )
      return render_plugin_error(result.error_key, 422) unless result.success

      render json: success_json.merge(topic_id: topic.id, upload_id: upload.id)
    rescue RateLimiter::LimitExceeded
      render_plugin_error(:rate_limited, 429)
    end

    private

    # Disallow SVG (different cook path / inline content) and require that the
    # Upload record actually looks like a raster image (width recorded by
    # Discourse during processing). This is a server-side check independent
    # of the frontend uploader's image-only filter.
    def valid_image_upload?(upload)
      extension = upload.extension.to_s.downcase
      return false if extension.blank?
      return false if extension == "svg" || extension == "svgz"
      return false unless FileHelper.is_supported_image?("image.#{extension}")
      upload.width.to_i.positive? && upload.height.to_i.positive?
    end

    def apply_rate_limit!
      return if current_user.staff?
      RateLimiter.new(
        current_user,
        "revised-critique-image",
        RATE_LIMIT_MAX,
        RATE_LIMIT_PERIOD
      ).performed!
    end

    def render_eligibility_error(eligibility)
      status =
        case eligibility.error_key
        when :plugin_disabled
          403
        when :cannot_edit_post
          403
        else
          422
        end
      render_plugin_error(eligibility.error_key, status)
    end

    def render_plugin_error(key, status)
      render json: {
               errors: [
                 I18n.t("discourse_revised_critique_image.errors.#{key}")
               ],
               error_key: key
             },
             status: status
    end
  end
end
