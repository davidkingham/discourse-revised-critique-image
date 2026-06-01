# frozen_string_literal: true

# Atomicity coverage for the single-image RevisionAdder. Mirrors the
# Phase-3 hardening applied to ProjectRevisionAdder: a refusal or
# exception from PostRevisor#revise! must leave both the JSON revision
# history and the first post body untouched, regardless of mode.
describe DiscourseRevisedCritiqueImage::RevisionAdder do
  fab!(:category)
  fab!(:owner) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) do
    Fabricate(:topic, category: category, user: owner, title: "Critique my image please")
  end
  fab!(:first_post) do
    Fabricate(:post, topic: topic, user: owner, raw: "Original body for critique.")
  end
  fab!(:reply) { Fabricate(:post, topic: topic, user: other_user, raw: "Feedback") }

  def fab_upload(name)
    Fabricate(:upload, user: owner, original_filename: name, width: 800, height: 600)
  end

  before do
    enable_current_plugin
    SiteSetting.revised_critique_category_id = category.id
    SiteSetting.revised_critique_max_revisions = 3
  end

  describe "happy path (control)" do
    it "writes history AND post raw together on add" do
      u = fab_upload("rev1.png")
      result = described_class.call(topic: topic, upload: u, user: owner, note: "first", mode: :add)
      expect(result.success).to eq(true)

      reloaded_history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload)
      expect(reloaded_history.count).to eq(1)
      expect(reloaded_history.latest["upload_id"]).to eq(u.id)
      expect(topic.first_post.reload.raw).to include(u.short_url)
    end
  end

  describe "PostRevisor returns false" do
    before { allow_any_instance_of(PostRevisor).to receive(:revise!).and_return(false) }

    it "returns the existing :revision_failed Result and does not persist history" do
      raw_before = topic.first_post.reload.raw
      u = fab_upload("rev1.png")
      result = described_class.call(topic: topic, upload: u, user: owner, note: "first", mode: :add)

      expect(result.success).to eq(false)
      expect(result.error_key).to eq(:revision_failed)

      reloaded_history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload)
      expect(reloaded_history.count).to eq(0)
      expect(topic.first_post.reload.raw).to eq(raw_before)
    end

    it "also rolls back the denormalised latest-revision custom fields" do
      u = fab_upload("rev1.png")
      described_class.call(topic: topic, upload: u, user: owner, note: nil, mode: :add)

      topic.reload
      expect(
        topic.custom_fields[DiscourseRevisedCritiqueImage::REVISED_IMAGE_UPLOAD_ID],
      ).to be_blank
      expect(topic.custom_fields[DiscourseRevisedCritiqueImage::REVISED_IMAGE_HISTORY]).to be_blank
    end

    it "preserves the prior latest revision when replace_latest fails" do
      # Establish a known-good first revision with the stub OFF.
      allow_any_instance_of(PostRevisor).to receive(:revise!).and_call_original
      good_upload = fab_upload("rev1-good.png")
      described_class.call(topic: topic, upload: good_upload, user: owner, note: "good", mode: :add)
      good_snapshot =
        DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload).latest.deep_dup
      raw_before = topic.first_post.reload.raw

      # Re-enable failure stub for the doomed replace_latest.
      allow_any_instance_of(PostRevisor).to receive(:revise!).and_return(false)
      doomed_upload = fab_upload("rev1-doomed.png")
      result =
        described_class.call(
          topic: topic,
          upload: doomed_upload,
          user: owner,
          note: "bad",
          mode: :replace_latest,
        )
      expect(result.success).to eq(false)

      after_history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload)
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

    it "rolls back history and post raw and propagates the exception" do
      raw_before = topic.first_post.reload.raw
      u = fab_upload("rev1.png")

      expect {
        described_class.call(topic: topic, upload: u, user: owner, note: nil, mode: :add)
      }.to raise_error(StandardError, "revisor exploded")

      reloaded_history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload)
      expect(reloaded_history.count).to eq(0)
      expect(topic.first_post.reload.raw).to eq(raw_before)
    end

    it "preserves the prior latest revision on replace_latest" do
      allow_any_instance_of(PostRevisor).to receive(:revise!).and_call_original
      good_upload = fab_upload("rev1-good.png")
      described_class.call(topic: topic, upload: good_upload, user: owner, note: "good", mode: :add)
      good_snapshot =
        DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload).latest.deep_dup
      raw_before = topic.first_post.reload.raw

      allow_any_instance_of(PostRevisor).to receive(:revise!).and_raise(
        StandardError,
        "revisor exploded",
      )
      doomed_upload = fab_upload("rev1-doomed.png")

      expect {
        described_class.call(
          topic: topic,
          upload: doomed_upload,
          user: owner,
          note: "bad",
          mode: :replace_latest,
        )
      }.to raise_error(StandardError, "revisor exploded")

      after_history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload)
      expect(after_history.count).to eq(1)
      expect(after_history.latest).to eq(good_snapshot)
      expect(topic.first_post.reload.raw).to eq(raw_before)
    end
  end
end
