# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  module TopicViewSerializerExtension
    def self.prepended(base)
      base.attributes :revised_critique_image, :can_add_revised_critique_image
    end

    def revised_critique_image
      upload_id = object.topic.custom_fields[REVISED_IMAGE_UPLOAD_ID]
      return nil if upload_id.blank?

      {
        upload_id: upload_id.to_i,
        added_at: object.topic.custom_fields[REVISED_IMAGE_ADDED_AT],
        added_by_user_id:
          object.topic.custom_fields[REVISED_IMAGE_ADDED_BY_USER_ID]&.to_i
      }
    end

    def can_add_revised_critique_image
      return false if scope&.user.blank?
      Eligibility.check(topic: object.topic, user: scope.user).ok
    end
  end
end
