# frozen_string_literal: true

describe DiscourseRevisedCritiqueImage::ProjectRevisionsController do
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

  let(:endpoint) { "/revised-critique-image/topics/#{topic.id}/project-revisions.json" }

  # Two uploads representing the original project's image slots.
  fab!(:orig_upload_a) do
    Fabricate(:upload, user: owner, original_filename: "orig-a.jpeg", width: 800, height: 600)
  end
  fab!(:orig_upload_b) do
    Fabricate(:upload, user: owner, original_filename: "orig-b.jpeg", width: 800, height: 600)
  end

  def fab_upload(name)
    Fabricate(:upload, user: owner, original_filename: name, width: 800, height: 600)
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
          "caption" => "Original caption A",
          "alt" => "Image 1",
        },
        {
          "id" => "slot-b",
          "position" => 2,
          "upload_id" => orig_upload_b.id,
          "short_url" => orig_upload_b.short_url,
          "caption" => "Original caption B",
          "alt" => "Image 2",
        },
      ],
    }
    topic.save_custom_fields(true)
  end

  def install_first_post_with_markers!(prefix: "Above the markers.", suffix: "Below the markers.")
    Fabricate(
      :post,
      topic: topic,
      user: owner,
      raw: [prefix, begin_marker, "original generated content", end_marker, suffix].join("\n\n"),
    )
  end

  before do
    enable_current_plugin
    SiteSetting.revised_critique_category_id = category.id
    SiteSetting.revised_critique_max_project_revisions = 3
    sign_in(owner)
    install_project_payload!
    install_first_post_with_markers!
    Fabricate(:post, topic: topic, user: other_user, raw: "Feedback reply.")
  end

  def post_revision(images:, mode: "add", note: nil)
    post endpoint, params: { mode: mode, note: note, images: images }
  end

  def image_param(id:, upload_id:, caption: "")
    { "id" => id, "upload_id" => upload_id, "caption" => caption }
  end

  describe "add first project revision" do
    it "appends Revision 1 with based_on=0 and 200" do
      new_a = fab_upload("rev1-a.jpeg")
      post_revision(
        images: [image_param(id: "slot-a", upload_id: new_a.id, caption: "Brighter shadows")],
        note: "First revision",
      )

      expect(response.status).to eq(200)
      expect(response.parsed_body["revision_number"]).to eq(1)
      expect(response.parsed_body["image_count"]).to eq(1)

      history = DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload)
      expect(history.count).to eq(1)
      expect(history.latest["based_on"]).to eq(0)
      expect(history.latest["note"]).to eq("First revision")
      expect(history.latest["images"].first["caption"]).to eq("Brighter shadows")
    end

    it "renders Latest expanded and Original Submission in [details]" do
      new_a = fab_upload("rev1-a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: new_a.id)])
      expect(response.status).to eq(200)

      raw = topic.reload.first_post.raw
      between = raw.split(begin_marker, 2).last.split(end_marker, 2).first
      expect(between).to include("### Project Overview")
      expect(between).to include('[details="Original Submission"]')
    end

    it "appends the title marker on first revision and not again on later writes" do
      new_a = fab_upload("rev1-a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: new_a.id)])
      expect(topic.reload.title).to end_with("(+revised)")

      new_a2 = fab_upload("rev2-a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: new_a2.id)])
      expect(topic.reload.title.scan("(+revised)").length).to eq(1)
    end

    it "preserves user-authored text outside the markers byte-for-byte" do
      raw_before = topic.first_post.reload.raw
      prefix = raw_before.split(begin_marker, 2).first
      suffix = raw_before.split(end_marker, 2).last

      new_a = fab_upload("rev1-a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: new_a.id)])
      expect(response.status).to eq(200)

      raw_after = topic.reload.first_post.raw
      expect(raw_after.split(begin_marker, 2).first).to eq(prefix)
      expect(raw_after.split(end_marker, 2).last).to eq(suffix)
    end
  end

  describe "second revision" do
    it "appends Revision 2 with based_on=1" do
      a = fab_upload("rev1-a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
      expect(response.status).to eq(200)

      b = fab_upload("rev2-a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: b.id)])
      expect(response.status).to eq(200)

      history = DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload)
      expect(history.count).to eq(2)
      expect(history.latest["revision_number"]).to eq(2)
      expect(history.latest["based_on"]).to eq(1)
    end

    it "renders Revision 1 collapsed under the new latest" do
      a = fab_upload("rev1-a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
      b = fab_upload("rev2-a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: b.id)])

      raw = topic.reload.first_post.raw
      between = raw.split(begin_marker, 2).last.split(end_marker, 2).first

      latest_index = between.index("### Project Overview")
      rev1_index = between.index('[details="Revision 1"]')
      orig_index = between.index('[details="Original Submission"]')
      expect(latest_index).to be < rev1_index
      expect(rev1_index).to be < orig_index
    end
  end

  describe "replace_latest" do
    it "is rejected when no project revision exists" do
      a = fab_upload("draft.jpeg")
      post_revision(mode: "replace_latest", images: [image_param(id: "slot-a", upload_id: a.id)])
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("no_project_revision_to_replace")
    end

    it "swaps the latest entry without bumping revision_number" do
      a = fab_upload("rev1-a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
      expect(response.status).to eq(200)

      a2 = fab_upload("rev1b-a.jpeg")
      post_revision(
        mode: "replace_latest",
        images: [image_param(id: "slot-a", upload_id: a2.id, caption: "fixed")],
        note: "corrected",
      )
      expect(response.status).to eq(200)

      history = DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload)
      expect(history.count).to eq(1)
      expect(history.latest["revision_number"]).to eq(1)
      expect(history.latest["note"]).to eq("corrected")
      expect(history.latest["images"].first["upload_id"]).to eq(a2.id)
    end
  end

  describe "image validation" do
    it "rejects empty image lists" do
      post_revision(images: [])
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("images_required")
    end

    it "rejects more than the configured maximum" do
      SiteSetting.revised_critique_max_project_images = 2
      a = fab_upload("a.jpeg")
      b = fab_upload("b.jpeg")
      c = fab_upload("c.jpeg")
      post_revision(
        images: [
          image_param(id: "a", upload_id: a.id),
          image_param(id: "b", upload_id: b.id),
          image_param(id: "c", upload_id: c.id),
        ],
      )
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("too_many_images")
    end

    it "accepts fewer images than the original submission" do
      # Original had 2 images; submit a revision with just 1.
      a = fab_upload("rev1-a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
      expect(response.status).to eq(200)
      history = DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload)
      expect(history.latest["images"].length).to eq(1)
    end

    it "rejects duplicate stable ids in the same payload" do
      a = fab_upload("a.jpeg")
      b = fab_upload("b.jpeg")
      post_revision(
        images: [
          image_param(id: "slot-x", upload_id: a.id),
          image_param(id: "slot-x", upload_id: b.id),
        ],
      )
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("duplicate_image_ids")
    end

    it "rejects an SVG upload" do
      svg =
        Fabricate(
          :upload,
          user: owner,
          original_filename: "x.svg",
          extension: "svg",
          width: 100,
          height: 100,
        )
      post_revision(images: [image_param(id: "slot-a", upload_id: svg.id)])
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("invalid_image_payload")
    end

    it "rejects a non-existent upload id" do
      post_revision(images: [image_param(id: "slot-a", upload_id: 999_999)])
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("invalid_image_payload")
    end

    it "rejects a note longer than the configured max" do
      SiteSetting.revised_critique_note_max_length = 10
      a = fab_upload("a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)], note: "x" * 50)
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("note_too_long")
    end
  end

  describe "eligibility / topic state" do
    it "rejects when project markers are missing from the first post" do
      topic.first_post.update!(raw: "no markers, no project block")
      a = fab_upload("a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
      # ProjectEligibility's project_data_invalid catches this first since
      # the reader requires markers for valid?.
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("project_data_invalid")

      # No history written, no post mutation either.
      expect(DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload).count).to eq(0)
    end

    it "rejects when the project submission data is missing" do
      topic.custom_fields[data_key] = nil
      topic.save_custom_fields(true)
      a = fab_upload("a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("project_data_invalid")
    end

    it "rejects when the topic is not a project topic" do
      topic.custom_fields[submission_type_key] = nil
      topic.custom_fields[data_key] = nil
      topic.save_custom_fields(true)
      topic.first_post.update!(raw: "plain post, not a project")

      a = fab_upload("a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("not_a_project_topic")
    end

    it "rejects non-OP users" do
      sign_in(other_user)
      a = fab_upload("a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("not_owner")
    end

    it "rejects when the topic is closed" do
      topic.update!(closed: true)
      a = fab_upload("a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
      expect(response.status).to eq(403)
      expect(response.parsed_body["error_key"]).to eq("cannot_edit_post")
    end

    it "rejects when at max revisions on add" do
      SiteSetting.revised_critique_max_project_revisions = 1
      a = fab_upload("rev1.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
      expect(response.status).to eq(200)

      b = fab_upload("rev2.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: b.id)])
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("max_project_revisions_reached")
    end

    it "still allows replace_latest at max" do
      SiteSetting.revised_critique_max_project_revisions = 1
      a = fab_upload("rev1.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
      expect(response.status).to eq(200)

      b = fab_upload("rev1b.jpeg")
      post_revision(mode: "replace_latest", images: [image_param(id: "slot-a", upload_id: b.id)])
      expect(response.status).to eq(200)
    end
  end

  describe "rate limiting" do
    it "limits non-staff" do
      RateLimiter.enable
      freeze_time
      stub_const(DiscourseRevisedCritiqueImage::ProjectRevisionsController, :RATE_LIMIT_MAX, 1) do
        a = fab_upload("rev1.jpeg")
        post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
        expect(response.status).to eq(200)

        b = fab_upload("rev2.jpeg")
        post_revision(images: [image_param(id: "slot-a", upload_id: b.id)])
        expect(response.status).to eq(429)
        expect(response.parsed_body["error_key"]).to eq("rate_limited")
      end
    ensure
      RateLimiter.disable
    end
  end

  describe "auth" do
    it "rejects anonymous requests" do
      sign_out
      a = fab_upload("a.jpeg")
      post_revision(images: [image_param(id: "slot-a", upload_id: a.id)])
      expect(response.status).to eq(403)
    end
  end
end
