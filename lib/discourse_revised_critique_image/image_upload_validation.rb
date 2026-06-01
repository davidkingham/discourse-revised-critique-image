# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Shared server-side guard against non-image / SVG / corrupt uploads.
  # Both the single-image and project-revision controllers rely on this so
  # the validation rule moves once when Discourse's upload model changes.
  #
  # The check is intentionally conservative: it requires that Discourse
  # successfully ran its image-processing pipeline and recorded a positive
  # width/height on the Upload row. A file whose row is missing those is
  # either still processing or wasn't recognised as an image at all, and
  # in either case is unsafe to insert into the rendered post markdown.
  module ImageUploadValidation
    module_function

    def valid_image_upload?(upload)
      return false if upload.blank?

      extension = upload.extension.to_s.downcase
      return false if extension.blank?
      # SVG is a different cook path and supports inline scripting. Refuse it
      # even though `is_supported_image?` may accept it depending on the
      # site's allow-list.
      return false if extension == "svg" || extension == "svgz"
      return false unless FileHelper.is_supported_image?("image.#{extension}")
      upload.width.to_i.positive? && upload.height.to_i.positive?
    end
  end
end
