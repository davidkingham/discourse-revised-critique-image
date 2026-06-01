# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # POST /revised-critique-image/topics/:topic_id/project-revisions
  #
  # Parallels RevisionsController for the project critique flow. The
  # heavy lifting (validation, history mutation, post rewrite) lives in
  # ProjectRevisionAdder; this controller is just plumbing for auth,
  # eligibility, rate-limit, and turning service Results into JSON.
  class ProjectRevisionsController < ::ApplicationController
    requires_plugin DiscourseRevisedCritiqueImage::PLUGIN_NAME

    RATE_LIMIT_MAX = 6
    RATE_LIMIT_PERIOD = 1.hour

    before_action :ensure_logged_in

    def create
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::NotFound if topic.blank?
      raise Discourse::NotFound unless guardian.can_see?(topic)

      mode = parse_mode
      return render_plugin_error(:invalid_mode, 422) if mode.nil?

      eligibility = ProjectEligibility.check(topic: topic, user: current_user, mode: mode)
      return render_eligibility_error(eligibility) unless eligibility.ok

      first_post = topic.first_post
      unless first_post && guardian.can_edit?(first_post)
        return render_plugin_error(:cannot_edit_post, 403)
      end

      images = parse_images
      note = params[:note].to_s.strip
      max_note = SiteSetting.revised_critique_note_max_length.to_i
      return render_plugin_error(:note_too_long, 422) if max_note > 0 && note.length > max_note

      apply_rate_limit!

      result =
        ProjectRevisionAdder.call(
          topic: topic,
          user: current_user,
          images: images,
          mode: mode,
          note: note,
        )

      unless result.success?
        meta = result.error_meta || {}
        return render_plugin_error(result.error_key, 422, meta: meta)
      end

      render json:
               success_json.merge(
                 topic_id: topic.id,
                 mode: mode,
                 revision_number: result.revision["revision_number"],
                 image_count: result.revision["images"].length,
               )
    rescue RateLimiter::LimitExceeded
      render_plugin_error(:rate_limited, 429)
    end

    private

    def parse_mode
      raw = params[:mode].presence || "add"
      sym = raw.to_s.to_sym
      ProjectEligibility::MODES.include?(sym) ? sym : nil
    end

    # Accept either an Array (JSON body parsed by Rails) or
    # ActionController::Parameters-wrapped Array. Per-image fields are
    # validated by ProjectRevisionAdder, which is the source of truth
    # for the image-shape rules.
    def parse_images
      raw = params[:images]
      return [] if raw.blank?
      Array(raw).map { |img| img.respond_to?(:to_unsafe_h) ? img.to_unsafe_h : img }
    end

    def apply_rate_limit!
      return if current_user.staff?
      RateLimiter.new(
        current_user,
        "revised-critique-project-revision",
        RATE_LIMIT_MAX,
        RATE_LIMIT_PERIOD,
      ).performed!
    end

    def render_eligibility_error(eligibility)
      status =
        case eligibility.error_key
        when :plugin_disabled, :cannot_edit_post
          403
        else
          422
        end
      render_plugin_error(eligibility.error_key, status)
    end

    def render_plugin_error(key, status, meta: {})
      message = I18n.t("discourse_revised_critique_image.errors.#{key}", **meta.symbolize_keys)
      render json: { errors: [message], error_key: key }, status: status
    end
  end
end
