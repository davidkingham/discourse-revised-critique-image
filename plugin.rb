# frozen_string_literal: true

# name: discourse-npn-revised-critique
# about: Lets the OP of an image critique topic share a revised version after receiving feedback.
# version: 2.0.0
# authors: David Kingham
# url: https://github.com/davidkingham/discourse-npn-revised-critique
# license: MIT

enabled_site_setting :revised_critique_enabled

register_asset "stylesheets/revised-critique-image.scss"

register_svg_icon "image"
register_svg_icon "arrows-rotate"
register_svg_icon "plus"

module ::DiscourseRevisedCritiqueImage
  PLUGIN_NAME = "discourse-npn-revised-critique"

  # JSON-encoded history of every revision a topic has had. Source of truth
  # from v2.0 onwards. Each entry shape is documented in RevisionHistory.
  REVISED_IMAGE_HISTORY = "revised_image_history"

  # Denormalised "latest revision" fields. Kept in sync with the last entry
  # of the history so that legacy serializers and external integrations can
  # read the current state without parsing the JSON.
  REVISED_IMAGE_UPLOAD_ID = "revised_image_upload_id"
  REVISED_IMAGE_ADDED_AT = "revised_image_added_at"
  REVISED_IMAGE_ADDED_BY_USER_ID = "revised_image_added_by_user_id"
  REVISED_IMAGE_NOTE = "revised_image_note"

  # Phase 3: project revision storage. The submissions plugin owns the
  # immutable original payload at `npn_project_submission_data`; this plugin
  # owns the ordered list of revisions appended after it.
  PROJECT_REVISIONS_KEY = "npn_project_revisions"
  PROJECT_REVISIONS_SCHEMA_KEY = "npn_project_revisions_schema"
  PROJECT_REVISIONS_SCHEMA_VERSION = 1
end

require_relative "lib/discourse_revised_critique_image/engine"

after_initialize do
  require_relative "lib/discourse_revised_critique_image/image_upload_validation"
  require_relative "lib/discourse_revised_critique_image/submissions_compat"
  require_relative "lib/discourse_revised_critique_image/project_submission_reader"
  require_relative "lib/discourse_revised_critique_image/project_revision_history"
  require_relative "lib/discourse_revised_critique_image/project_revision_renderer"
  require_relative "lib/discourse_revised_critique_image/project_revision_adder"
  require_relative "lib/discourse_revised_critique_image/project_eligibility"
  require_relative "lib/discourse_revised_critique_image/npn_metadata"
  require_relative "lib/discourse_revised_critique_image/revision_history"
  require_relative "lib/discourse_revised_critique_image/revision_adder"
  require_relative "lib/discourse_revised_critique_image/eligibility"
  require_relative "app/controllers/discourse_revised_critique_image/revisions_controller"
  require_relative "app/controllers/discourse_revised_critique_image/project_revisions_controller"
  require_relative "lib/extensions/topic_view_serializer_extension"

  Discourse::Application.routes.append do
    mount ::DiscourseRevisedCritiqueImage::Engine, at: "/revised-critique-image"
  end

  Topic.register_custom_field_type(DiscourseRevisedCritiqueImage::REVISED_IMAGE_HISTORY, :json)
  Topic.register_custom_field_type(DiscourseRevisedCritiqueImage::REVISED_IMAGE_UPLOAD_ID, :integer)
  Topic.register_custom_field_type(
    DiscourseRevisedCritiqueImage::REVISED_IMAGE_ADDED_BY_USER_ID,
    :integer,
  )
  Topic.register_custom_field_type(DiscourseRevisedCritiqueImage::REVISED_IMAGE_ADDED_AT, :string)
  Topic.register_custom_field_type(DiscourseRevisedCritiqueImage::REVISED_IMAGE_NOTE, :string)

  # NPN-namespaced snapshot of revision images, consumed by sibling plugins
  # (discourse-npn-critique-reply). Registered with their respective types so
  # they round-trip cleanly between Ruby and the topic_custom_fields table.
  Topic.register_custom_field_type(
    DiscourseRevisedCritiqueImage::NpnMetadata::REVISION_COUNT,
    :integer,
  )
  Topic.register_custom_field_type(
    DiscourseRevisedCritiqueImage::NpnMetadata::LATEST_REVISION_UPLOAD_ID,
    :integer,
  )
  Topic.register_custom_field_type(
    DiscourseRevisedCritiqueImage::NpnMetadata::LATEST_REVISION_IMAGE_URL,
    :string,
  )
  Topic.register_custom_field_type(
    DiscourseRevisedCritiqueImage::NpnMetadata::REVISION_IMAGES,
    :json,
  )
  Topic.register_custom_field_type(DiscourseRevisedCritiqueImage::NpnMetadata::SCHEMA, :integer)

  # Defensively co-register the sibling submissions plugin's structured
  # project payload as :json so the Hash round-trips correctly through
  # topic_custom_fields even when discourse-npn-submissions isn't loaded
  # (e.g. in this plugin's own CI checkout, which clones it standalone).
  # When the submissions plugin IS loaded, this is a redundant — and
  # idempotent — registration: it owns the field, we only ever read it.
  Topic.register_custom_field_type(
    DiscourseRevisedCritiqueImage::SubmissionsCompat.project_data_key,
    :json,
  )

  # Phase 3: project revision storage. Owned by this plugin.
  Topic.register_custom_field_type(DiscourseRevisedCritiqueImage::PROJECT_REVISIONS_KEY, :json)
  Topic.register_custom_field_type(
    DiscourseRevisedCritiqueImage::PROJECT_REVISIONS_SCHEMA_KEY,
    :integer,
  )

  TopicList.preloaded_custom_fields << DiscourseRevisedCritiqueImage::REVISED_IMAGE_UPLOAD_ID
  TopicList.preloaded_custom_fields << DiscourseRevisedCritiqueImage::NpnMetadata::LATEST_REVISION_UPLOAD_ID
  TopicList.preloaded_custom_fields << DiscourseRevisedCritiqueImage::NpnMetadata::LATEST_REVISION_IMAGE_URL

  TopicViewSerializer.prepend DiscourseRevisedCritiqueImage::TopicViewSerializerExtension
end
