# frozen_string_literal: true

# Phase 2 handoff coverage: prove the Phase 1 project payload written by
# discourse-npn-submissions surfaces correctly on TopicViewSerializer
# without disturbing the existing single-image attributes.
describe TopicViewSerializer do
  fab!(:category)
  fab!(:owner) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) do
    Fabricate(:topic, category: category, user: owner, title: "Project submission topic title")
  end
  fab!(:first_post) do
    Fabricate(:post, topic: topic, user: owner, raw: "Plain body, no markers, no project.")
  end
  fab!(:admin)

  let(:submission_type_key) { DiscourseRevisedCritiqueImage::SubmissionsCompat.submission_type_key }
  let(:data_key) { DiscourseRevisedCritiqueImage::SubmissionsCompat.project_data_key }
  let(:begin_marker) { DiscourseRevisedCritiqueImage::SubmissionsCompat.block_begin }
  let(:end_marker) { DiscourseRevisedCritiqueImage::SubmissionsCompat.block_end }

  def serialize(viewer)
    topic_view = TopicView.new(topic.id, viewer)
    json = TopicViewSerializer.new(topic_view, scope: Guardian.new(viewer), root: false).as_json
    JSON.parse(MultiJson.dump(json))
  end

  def well_formed_image(position:)
    {
      "id" => "a1b2c3d4e5f6071#{position}",
      "position" => position,
      "upload_id" => 100 + position,
      "short_url" => "upload://abc#{position}.jpeg",
      "caption" => "",
      "alt" => "Image #{position}",
    }
  end

  def install_project_payload!(images:)
    topic.custom_fields[submission_type_key] = "project_critique"
    topic.custom_fields[data_key] = {
      "type" => "project_critique",
      "version" => 1,
      "images" => images,
    }
    topic.save_custom_fields(true)
    first_post.update!(
      raw: [begin_marker, "<!-- generated -->", end_marker, "\nuser-authored tail"].join("\n\n"),
    )
  end

  before { enable_current_plugin }

  describe "non-project topics" do
    it "reports revision_type single_image with no project flags set" do
      json = serialize(owner)
      expect(json["revised_critique_revision_type"]).to eq("single_image")
      expect(json["revised_critique_project_detected"]).to eq(false)
      expect(json["revised_critique_project_valid"]).to eq(false)
      expect(json["revised_critique_project_image_count"]).to eq(0)
    end
  end

  describe "valid project topics" do
    before { install_project_payload!(images: [well_formed_image(position: 1)]) }

    it "reports revision_type project with valid=true and the image count" do
      json = serialize(owner)
      expect(json["revised_critique_revision_type"]).to eq("project")
      expect(json["revised_critique_project_detected"]).to eq(true)
      expect(json["revised_critique_project_valid"]).to eq(true)
      expect(json["revised_critique_project_image_count"]).to eq(1)
    end

    it "exposes the image count for multi-image projects" do
      install_project_payload!(
        images: [
          well_formed_image(position: 1),
          well_formed_image(position: 2),
          well_formed_image(position: 3),
        ],
      )
      json = serialize(owner)
      expect(json["revised_critique_project_image_count"]).to eq(3)
    end
  end

  describe "invalid project payloads" do
    it "does not crash serialization when images is missing" do
      topic.custom_fields[submission_type_key] = "project_critique"
      topic.custom_fields[data_key] = { "type" => "project_critique", "version" => 1 }
      topic.save_custom_fields(true)

      expect { serialize(owner) }.not_to raise_error
      json = serialize(owner)
      expect(json["revised_critique_revision_type"]).to eq("project")
      expect(json["revised_critique_project_detected"]).to eq(true)
      expect(json["revised_critique_project_valid"]).to eq(false)
    end

    it "hides the error_key from non-staff viewers" do
      install_project_payload!(images: [well_formed_image(position: 1)])
      # Force an invalid state by removing markers from the first post.
      first_post.update!(raw: "no markers")

      json = serialize(owner)
      expect(json["revised_critique_project_valid"]).to eq(false)
      expect(json["revised_critique_project_error_key"]).to be_nil
    end

    it "exposes the error_key to staff for diagnostics" do
      install_project_payload!(images: [well_formed_image(position: 1)])
      first_post.update!(raw: "no markers")

      json = serialize(admin)
      expect(json["revised_critique_project_valid"]).to eq(false)
      expect(json["revised_critique_project_error_key"]).to eq("markers_missing")
    end
  end

  describe "single-image attributes are unaffected" do
    it "still emits the existing can_* and history attributes" do
      json = serialize(owner)
      expect(json).to have_key("can_add_revised_critique_image")
      expect(json).to have_key("can_replace_latest_revised_critique_image")
      expect(json).to have_key("revised_critique_image_revision_count")
      expect(json).to have_key("revised_critique_image_max_revisions")
    end
  end

  # Phase 2.5 cross-check: detection alone isn't enough, the eligibility
  # gate must actually flip the single-image can_* booleans off on
  # project topics so the frontend buttons disappear.
  describe "single-image eligibility is gated off on project topics" do
    let!(:reply) { Fabricate(:post, topic: topic, user: Fabricate(:user), raw: "Feedback") }

    before do
      SiteSetting.revised_critique_category_id = category.id
      install_project_payload!(images: [well_formed_image(position: 1)])
    end

    it "reports can_add_revised_critique_image = false" do
      json = serialize(owner)
      expect(json["can_add_revised_critique_image"]).to eq(false)
    end

    it "reports can_replace_latest_revised_critique_image = false" do
      json = serialize(owner)
      expect(json["can_replace_latest_revised_critique_image"]).to eq(false)
    end

    it "does not crash when the project payload is malformed" do
      topic.custom_fields[data_key] = { "type" => "project_critique" }
      topic.save_custom_fields(true)

      expect { serialize(owner) }.not_to raise_error
      json = serialize(owner)
      # Gate still fires because the topic is still flagged as a project
      # via npn_submission_type, even if the structured payload is bad.
      expect(json["can_add_revised_critique_image"]).to eq(false)
      expect(json["can_replace_latest_revised_critique_image"]).to eq(false)
    end
  end

  # Sanity: the gate is targeted, not a blanket "always false" change.
  # A normal single-image topic in the configured category with the
  # required reply present still gets can_add = true.
  describe "single-image eligibility on non-project topics is unchanged" do
    let!(:reply) { Fabricate(:post, topic: topic, user: Fabricate(:user), raw: "Feedback") }

    before { SiteSetting.revised_critique_category_id = category.id }

    it "still reports can_add_revised_critique_image = true" do
      json = serialize(owner)
      expect(json["can_add_revised_critique_image"]).to eq(true)
    end
  end

  # Phase 4: project_revision_editor baseline payload — visible only to
  # users with edit rights so normal members don't receive image URLs
  # they have no use for.
  describe "project_revision_editor baseline" do
    let!(:reply) { Fabricate(:post, topic: topic, user: Fabricate(:user), raw: "Feedback") }

    before do
      SiteSetting.revised_critique_category_id = category.id
      install_project_payload!(images: [well_formed_image(position: 1)])
    end

    it "exposes the original baseline to the OP" do
      json = serialize(owner)
      editor = json["project_revision_editor"]
      expect(editor).to be_a(Hash)
      expect(editor["original"]).to be_a(Hash)
      expect(editor["original"]["images"].length).to eq(1)
    end

    it "is hidden from non-OP non-staff viewers" do
      other = Fabricate(:user)
      json = serialize(other)
      expect(json["project_revision_editor"]).to be_nil
    end

    it "includes a 'latest' baseline once at least one revision exists" do
      DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic).add!(
        images: [
          {
            "id" => "slot-a",
            "position" => 1,
            "upload_id" => 999,
            "short_url" => "upload://abc.jpeg",
            "caption" => "rev1 caption",
            "alt" => "Image 1",
            "status" => "new",
          },
        ],
        user: owner,
        note: "first revision",
      )

      json = serialize(owner)
      editor = json["project_revision_editor"]
      expect(editor["latest"]).to be_a(Hash)
      expect(editor["latest"]["note"]).to eq("first revision")
      expect(editor["latest"]["images"].first["caption"]).to eq("rev1 caption")
    end
  end
end
