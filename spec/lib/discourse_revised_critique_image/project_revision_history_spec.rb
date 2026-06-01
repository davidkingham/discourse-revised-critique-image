# frozen_string_literal: true

describe DiscourseRevisedCritiqueImage::ProjectRevisionHistory do
  fab!(:owner, :user)
  fab!(:topic) { Fabricate(:topic, user: owner, title: "Project critique topic title") }

  subject(:history) { described_class.for(topic.reload) }

  def make_image(id:, position: 1, upload_id: 1, status: "new", caption: "")
    {
      "id" => id,
      "position" => position,
      "upload_id" => upload_id,
      "short_url" => "upload://#{id}.jpeg",
      "caption" => caption,
      "alt" => "Image #{position}",
      "status" => status,
    }
  end

  describe "#add!" do
    it "appends the first revision based_on the original" do
      entry = history.add!(images: [make_image(id: "slot-1")], user: owner, note: "first")
      expect(entry["revision_number"]).to eq(1)
      expect(entry["based_on"]).to eq(0)
      expect(entry["user_id"]).to eq(owner.id)
      expect(entry["note"]).to eq("first")
      expect(history.count).to eq(1)
    end

    it "increments revision_number and based_on for the second revision" do
      history.add!(images: [make_image(id: "slot-1")], user: owner, note: "r1")
      history.add!(images: [make_image(id: "slot-1")], user: owner, note: "r2")

      expect(history.entries.map { |e| e["revision_number"] }).to eq([1, 2])
      expect(history.entries.last["based_on"]).to eq(1)
    end

    it "normalises positions to 1..N regardless of input order" do
      images = [
        make_image(id: "a", position: 9),
        make_image(id: "b", position: 3),
        make_image(id: "c", position: 7),
      ]
      entry = history.add!(images: images, user: owner, note: nil)
      expect(entry["images"].map { |i| i["position"] }).to eq([1, 2, 3])
      expect(entry["images"].map { |i| i["id"] }).to eq(%w[a b c])
    end

    it "raises on duplicate image ids" do
      dup = [make_image(id: "x"), make_image(id: "x", upload_id: 2)]
      expect { history.add!(images: dup, user: owner, note: nil) }.to raise_error(
        ArgumentError,
        /duplicate image id/,
      )
    end

    it "raises when an image is missing a stable id" do
      bad = [make_image(id: "")]
      expect { history.add!(images: bad, user: owner, note: nil) }.to raise_error(
        ArgumentError,
        /missing stable id/,
      )
    end

    it "stamps the schema version on every write" do
      history.add!(images: [make_image(id: "slot-1")], user: owner, note: nil)
      expect(
        topic.reload.custom_fields[DiscourseRevisedCritiqueImage::PROJECT_REVISIONS_SCHEMA_KEY],
      ).to eq(DiscourseRevisedCritiqueImage::PROJECT_REVISIONS_SCHEMA_VERSION)
    end
  end

  describe "#replace_latest!" do
    it "raises when no revisions exist" do
      expect {
        history.replace_latest!(images: [make_image(id: "a")], user: owner, note: nil)
      }.to raise_error(/no project revision to replace/)
    end

    it "mutates the latest entry without incrementing revision_number" do
      history.add!(images: [make_image(id: "a")], user: owner, note: "first")
      original_created_at = history.entries.last["created_at"]

      history.replace_latest!(
        images: [make_image(id: "a", upload_id: 2)],
        user: owner,
        note: "fixed",
      )

      expect(history.entries.length).to eq(1)
      expect(history.entries.last["revision_number"]).to eq(1)
      expect(history.entries.last["note"]).to eq("fixed")
      expect(history.entries.last["created_at"]).to eq(original_created_at)
    end
  end

  describe "max gating" do
    it "respects revised_critique_max_project_revisions" do
      SiteSetting.revised_critique_max_project_revisions = 2
      history.add!(images: [make_image(id: "a")], user: owner, note: nil)
      history.add!(images: [make_image(id: "a")], user: owner, note: nil)
      expect(history.at_max?).to eq(true)
    end

    it "caps max_images at the hard limit of 12" do
      SiteSetting.revised_critique_max_project_images = 99
      expect(history.max_images).to eq(12)
    end
  end
end
