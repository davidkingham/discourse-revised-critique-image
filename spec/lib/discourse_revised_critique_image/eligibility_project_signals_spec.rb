# frozen_string_literal: true

# Coverage for the tiered project-signal check in Eligibility#project_topic?.
# The hardening intent: any single positive signal (tag, custom_field, or
# reader) is enough to block the single-image flow even if the others are
# missing or broken. Only the *absence* of all signals lets the gate fall
# through to normal single-image behaviour.
describe DiscourseRevisedCritiqueImage::Eligibility do
  fab!(:category)
  fab!(:owner) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) do
    Fabricate(:topic, category: category, user: owner, title: "Critique my project images")
  end
  fab!(:first_post) { Fabricate(:post, topic: topic, user: owner, raw: "Body for the project.") }
  fab!(:reply) do
    Fabricate(:post, topic: topic, user: other_user, raw: "Feedback from another user.")
  end

  let(:submission_type_key) { DiscourseRevisedCritiqueImage::SubmissionsCompat.submission_type_key }
  let(:data_key) { DiscourseRevisedCritiqueImage::SubmissionsCompat.project_data_key }

  before do
    SiteSetting.revised_critique_enabled = true
    SiteSetting.revised_critique_category_id = category.id
    SiteSetting.tagging_enabled = true
  end

  def check_add
    described_class.check(topic: topic.reload, user: owner, mode: :add)
  end

  def add_project_tag!
    project_tag =
      Tag.find_by(name: described_class::PROJECT_TAG_NAME) ||
        Fabricate(:tag, name: described_class::PROJECT_TAG_NAME)
    topic.tags << project_tag
  end

  def install_well_formed_project_payload!
    topic.custom_fields[submission_type_key] = "project_critique"
    topic.custom_fields[data_key] = {
      "type" => "project_critique",
      "version" => 1,
      "images" => [
        {
          "id" => "a1b2c3d4e5f60718",
          "position" => 1,
          "upload_id" => 42,
          "short_url" => "upload://abc.jpeg",
          "caption" => "",
          "alt" => "Image 1",
        },
      ],
    }
    topic.save_custom_fields(true)
  end

  def install_malformed_project_payload!
    # Has the submission_type flag, but the structured payload is missing
    # the keys the reader requires. The reader will classify this as
    # project? = true (because submission_type matches), valid? = false —
    # but the gate must block regardless of valid?.
    topic.custom_fields[submission_type_key] = "project_critique"
    topic.custom_fields[data_key] = { "type" => "project_critique" } # no version, no images
    topic.save_custom_fields(true)
  end

  describe "tag-only signal" do
    it "blocks single-image add when only the project tag is present" do
      add_project_tag!

      result = check_add
      expect(result.ok).to eq(false)
      expect(result.error_key).to eq(:project_topic_unsupported)
    end

    it "blocks even when ProjectSubmissionReader raises" do
      add_project_tag!
      allow(DiscourseRevisedCritiqueImage::ProjectSubmissionReader).to receive(:read).and_raise(
        StandardError,
        "reader exploded",
      )
      allow(Rails.logger).to receive(:warn)

      result = check_add
      expect(result.ok).to eq(false)
      expect(result.error_key).to eq(:project_topic_unsupported)
    end
  end

  describe "submission_type signal" do
    it "blocks when npn_submission_type is project_critique with malformed data" do
      install_malformed_project_payload!

      result = check_add
      expect(result.ok).to eq(false)
      expect(result.error_key).to eq(:project_topic_unsupported)
    end

    it "blocks when submission_type is set and the reader raises" do
      install_malformed_project_payload!
      allow(DiscourseRevisedCritiqueImage::ProjectSubmissionReader).to receive(:read).and_raise(
        StandardError,
        "reader exploded",
      )
      allow(Rails.logger).to receive(:warn)

      result = check_add
      expect(result.ok).to eq(false)
      expect(result.error_key).to eq(:project_topic_unsupported)
    end
  end

  describe "reader-only signal" do
    it "blocks when only the structured payload classifies as project" do
      install_well_formed_project_payload!

      result = check_add
      expect(result.ok).to eq(false)
      expect(result.error_key).to eq(:project_topic_unsupported)
    end
  end

  describe "fail-open behaviour" do
    it "lets single-image add through when no project signals exist and the reader raises" do
      allow(DiscourseRevisedCritiqueImage::ProjectSubmissionReader).to receive(:read).and_raise(
        StandardError,
        "reader exploded",
      )
      allow(Rails.logger).to receive(:warn)

      result = check_add
      expect(result.ok).to eq(true)
    end

    it "lets a plain non-project topic through" do
      result = check_add
      expect(result.ok).to eq(true)
    end
  end

  describe "probe independence" do
    # Belt-and-braces: confirm the gate stays closed even if a future
    # change to tag association handling makes project_tag_present? raise.
    it "blocks via submission_type even when the tag probe raises" do
      install_malformed_project_payload!
      allow(topic).to receive(:tags).and_raise(StandardError, "tag association broken")
      allow(Rails.logger).to receive(:warn)

      # Re-fetch to avoid the reload in check_add overwriting our stub.
      result = described_class.check(topic: topic, user: owner, mode: :add)
      expect(result.ok).to eq(false)
      expect(result.error_key).to eq(:project_topic_unsupported)
    end
  end
end
