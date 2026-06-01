# frozen_string_literal: true

# Phase 3 hardening: prove that ProjectRevisionAdder's write step is
# atomic. If PostRevisor#revise! refuses (returns false) or raises, the
# JSON revision history must not be mutated and the first post must
# round-trip byte-for-byte.
describe DiscourseRevisedCritiqueImage::ProjectRevisionAdder do
  fab!(:category)
  fab!(:owner) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) do
    Fabricate(:topic, category: category, user: owner, title: "Project critique topic title")
  end

  let(:submission_type_key) { DiscourseRevisedCritiqueImage::SubmissionsCompat.submission_type_key }
  let(:data_key) { DiscourseRevisedCritiqueImage::SubmissionsCompat.project_data_key }
  let(:begin_marker) { DiscourseRevisedCritiqueImage::SubmissionsCompat.block_begin }
  let(:end_marker) { DiscourseRevisedCritiqueImage::SubmissionsCompat.block_end }

  fab!(:orig_upload_a) do
    Fabricate(:upload, user: owner, original_filename: "orig-a.jpeg", width: 800, height: 600)
  end

  def fab_upload(name)
    Fabricate(:upload, user: owner, original_filename: name, width: 800, height: 600)
  end

  def image_param(id:, upload_id:, caption: "")
    { "id" => id, "upload_id" => upload_id, "caption" => caption }
  end

  def install_project_payload!
    topic.custom_fields[submission_type_key] = "project_critique"
    topic.custom_fields[data_key] = {
      "type" => "project_critique",
      "version" => 1,
      "images" => [
        {
          "id" => "slot-a",
          "position" => 1,
          "upload_id" => orig_upload_a.id,
          "short_url" => orig_upload_a.short_url,
          "caption" => "Original",
          "alt" => "Image 1",
        },
      ],
    }
    topic.save_custom_fields(true)
  end

  def install_first_post_with_markers!
    Fabricate(
      :post,
      topic: topic,
      user: owner,
      raw: ["Above", begin_marker, "original block", end_marker, "Below"].join("\n\n"),
    )
  end

  before do
    enable_current_plugin
    SiteSetting.revised_critique_category_id = category.id
    SiteSetting.revised_critique_max_project_revisions = 3
    install_project_payload!
    install_first_post_with_markers!
    Fabricate(:post, topic: topic, user: other_user, raw: "Feedback")
  end

  describe "happy path (control)" do
    it "writes history AND post raw together" do
      u = fab_upload("rev1.jpeg")
      result =
        described_class.call(
          topic: topic,
          user: owner,
          images: [image_param(id: "slot-a", upload_id: u.id)],
          mode: :add,
        )
      expect(result.success?).to eq(true)

      reloaded_history = DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload)
      expect(reloaded_history.count).to eq(1)
      expect(reloaded_history.latest["images"].first["upload_id"]).to eq(u.id)

      expect(topic.first_post.reload.raw).to include('[details="Original Submission"]')
    end
  end

  describe "PostRevisor returns false (refusal)" do
    before { allow_any_instance_of(PostRevisor).to receive(:revise!).and_return(false) }

    it "returns a :revision_failed Result" do
      u = fab_upload("rev1.jpeg")
      result =
        described_class.call(
          topic: topic,
          user: owner,
          images: [image_param(id: "slot-a", upload_id: u.id)],
          mode: :add,
        )
      expect(result.success?).to eq(false)
      expect(result.error_key).to eq(:revision_failed)
    end

    it "does not append a revision on add failure" do
      raw_before = topic.first_post.reload.raw
      u = fab_upload("rev1.jpeg")
      described_class.call(
        topic: topic,
        user: owner,
        images: [image_param(id: "slot-a", upload_id: u.id)],
        mode: :add,
      )

      reloaded_history = DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload)
      expect(reloaded_history.count).to eq(0)
      expect(topic.first_post.reload.raw).to eq(raw_before)
    end

    it "does not mutate the latest stored revision on replace_latest failure" do
      # Establish a known-good first revision with the stub OFF, then
      # turn the stub on for the failing replace_latest call.
      good_upload = fab_upload("rev1-good.jpeg")
      allow_any_instance_of(PostRevisor).to receive(:revise!).and_call_original
      described_class.call(
        topic: topic,
        user: owner,
        images: [image_param(id: "slot-a", upload_id: good_upload.id, caption: "good")],
        mode: :add,
      )
      good_history = DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload)
      expect(good_history.count).to eq(1)
      good_snapshot = good_history.latest.deep_dup
      raw_before = topic.first_post.reload.raw

      # Re-enable the failure stub for the replace attempt.
      allow_any_instance_of(PostRevisor).to receive(:revise!).and_return(false)

      doomed_upload = fab_upload("rev1-doomed.jpeg")
      result =
        described_class.call(
          topic: topic,
          user: owner,
          images: [image_param(id: "slot-a", upload_id: doomed_upload.id, caption: "bad")],
          mode: :replace_latest,
        )
      expect(result.success?).to eq(false)

      after_history = DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload)
      expect(after_history.count).to eq(1)
      expect(after_history.latest).to eq(good_snapshot)
      expect(topic.first_post.reload.raw).to eq(raw_before)
    end
  end

  describe "PostRevisor raises" do
    before do
      allow_any_instance_of(PostRevisor).to receive(:revise!).and_raise(
        StandardError,
        "revisor exploded",
      )
    end

    it "does not append a revision on add" do
      raw_before = topic.first_post.reload.raw
      u = fab_upload("rev1.jpeg")
      expect {
        described_class.call(
          topic: topic,
          user: owner,
          images: [image_param(id: "slot-a", upload_id: u.id)],
          mode: :add,
        )
      }.to raise_error(StandardError, "revisor exploded")

      reloaded_history = DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload)
      expect(reloaded_history.count).to eq(0)
      expect(topic.first_post.reload.raw).to eq(raw_before)
    end

    it "does not mutate the latest stored revision on replace_latest" do
      good_upload = fab_upload("rev1-good.jpeg")
      allow_any_instance_of(PostRevisor).to receive(:revise!).and_call_original
      described_class.call(
        topic: topic,
        user: owner,
        images: [image_param(id: "slot-a", upload_id: good_upload.id, caption: "good")],
        mode: :add,
      )
      good_snapshot =
        DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload).latest.deep_dup
      raw_before = topic.first_post.reload.raw

      allow_any_instance_of(PostRevisor).to receive(:revise!).and_raise(
        StandardError,
        "revisor exploded",
      )

      doomed_upload = fab_upload("rev1-doomed.jpeg")
      expect {
        described_class.call(
          topic: topic,
          user: owner,
          images: [image_param(id: "slot-a", upload_id: doomed_upload.id)],
          mode: :replace_latest,
        )
      }.to raise_error(StandardError, "revisor exploded")

      after_history = DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload)
      expect(after_history.count).to eq(1)
      expect(after_history.latest).to eq(good_snapshot)
      expect(topic.first_post.reload.raw).to eq(raw_before)
    end
  end
end
