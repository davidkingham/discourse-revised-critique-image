# frozen_string_literal: true

# Integration coverage for the NPN metadata snapshot written by every
# successful revision. Lives separately from revisions_controller_spec.rb so
# the latter can stay focused on auth/eligibility/rate-limiting.
describe "NPN revision image metadata" do
  fab!(:category)
  fab!(:owner) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) do
    Fabricate(:topic, category: category, user: owner, title: "Critique my image please")
  end
  fab!(:first_post) do
    Fabricate(:post, topic: topic, user: owner, raw: "Original critique image post.")
  end
  fab!(:reply_from_other_user) do
    Fabricate(:post, topic: topic, user: other_user, raw: "Some feedback for you.")
  end

  let(:endpoint) { "/revised-critique-image/topics/#{topic.id}/revisions.json" }
  let(:fields) { DiscourseRevisedCritiqueImage::NpnMetadata }

  def fab_upload(filename:, width: 800, height: 600)
    Fabricate(:upload, user: owner, original_filename: filename, width: width, height: height)
  end

  before do
    enable_current_plugin
    SiteSetting.revised_critique_category_id = category.id
    SiteSetting.revised_critique_max_revisions = 3
    sign_in(owner)
  end

  it "writes the npn fields on the first revision" do
    u1 = fab_upload(filename: "r1.png")

    post endpoint, params: { upload_id: u1.id, note: "Adjusted exposure." }
    expect(response.status).to eq(200)

    topic.reload
    expect(topic.custom_fields[fields::REVISION_COUNT]).to eq(1)
    expect(topic.custom_fields[fields::LATEST_REVISION_UPLOAD_ID]).to eq(u1.id)
    expect(topic.custom_fields[fields::LATEST_REVISION_IMAGE_URL]).to eq(u1.url)
    expect(topic.custom_fields[fields::SCHEMA]).to eq(fields::SCHEMA_VERSION)

    images = topic.custom_fields[fields::REVISION_IMAGES]
    expect(images.length).to eq(1)
    expect(images.first).to include(
      "revision_number" => 1,
      "upload_id" => u1.id,
      "image_url" => u1.url,
      "post_id" => first_post.id,
      "user_id" => owner.id,
      "note" => "Adjusted exposure.",
    )
  end

  it "appends a second revision and points latest fields at it" do
    u1 = fab_upload(filename: "r1.png")
    u2 = fab_upload(filename: "r2.png", width: 700, height: 500)

    post endpoint, params: { upload_id: u1.id, note: "first" }
    expect(response.status).to eq(200)
    post endpoint, params: { upload_id: u2.id, note: "second" }
    expect(response.status).to eq(200)

    topic.reload
    expect(topic.custom_fields[fields::REVISION_COUNT]).to eq(2)
    expect(topic.custom_fields[fields::LATEST_REVISION_UPLOAD_ID]).to eq(u2.id)
    expect(topic.custom_fields[fields::LATEST_REVISION_IMAGE_URL]).to eq(u2.url)

    images = topic.custom_fields[fields::REVISION_IMAGES]
    expect(images.map { |i| i["revision_number"] }).to eq([1, 2])
    expect(images.map { |i| i["upload_id"] }).to eq([u1.id, u2.id])
    expect(images[0]["note"]).to eq("first")
    expect(images[1]["note"]).to eq("second")
  end

  it "omits the note key when no note was provided" do
    u1 = fab_upload(filename: "r1.png")

    post endpoint, params: { upload_id: u1.id }
    expect(response.status).to eq(200)

    images = topic.reload.custom_fields[fields::REVISION_IMAGES]
    expect(images.first).not_to have_key("note")
  end

  it "self-heals a previously malformed npn_revision_images value" do
    # Simulate corrupt data left by an aborted external write.
    topic.custom_fields[fields::REVISION_IMAGES] = "not-a-json-array"
    topic.save_custom_fields(true)

    u1 = fab_upload(filename: "r1.png")
    post endpoint, params: { upload_id: u1.id }
    expect(response.status).to eq(200)

    images = topic.reload.custom_fields[fields::REVISION_IMAGES]
    expect(images).to be_an(Array)
    expect(images.length).to eq(1)
    expect(images.first["upload_id"]).to eq(u1.id)
  end

  it "does not touch npn_original_* fields owned by the submissions plugin" do
    # The submissions plugin registers these custom_field types in
    # production; we don't here, so values round-trip as strings. That's
    # fine for this test — we only care that this plugin doesn't mutate
    # whatever the submissions plugin wrote. Capture the post-save state
    # as the source of truth, then assert it's unchanged after our write.
    topic.custom_fields["npn_original_primary_image_upload_id"] = 123
    topic.custom_fields["npn_original_primary_image_url"] = "/uploads/default/original/1X/orig.jpg"
    topic.custom_fields["npn_original_image_upload_ids"] = [123]
    topic.custom_fields["npn_original_image_count"] = 1
    topic.save_custom_fields(true)

    original_values =
      topic.reload.custom_fields.slice(
        "npn_original_primary_image_upload_id",
        "npn_original_primary_image_url",
        "npn_original_image_upload_ids",
        "npn_original_image_count",
      )

    u1 = fab_upload(filename: "r1.png")
    post endpoint, params: { upload_id: u1.id }
    expect(response.status).to eq(200)

    after_values = topic.reload.custom_fields.slice(*original_values.keys)
    expect(after_values).to eq(original_values)
  end

  it "still completes the revision and logs a warning when the npn snapshot raises" do
    allow(DiscourseRevisedCritiqueImage::NpnMetadata).to receive(:apply!).and_raise(
      StandardError,
      "boom",
    )
    allow(Rails.logger).to receive(:warn)

    u1 = fab_upload(filename: "r1.png")
    post endpoint, params: { upload_id: u1.id, note: "still works" }

    expect(response.status).to eq(200)
    expect(Rails.logger).to have_received(:warn).with(
      a_string_matching(/NPN metadata snapshot failed/),
    )

    history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload)
    expect(history.count).to eq(1)
    expect(history.latest["upload_id"]).to eq(u1.id)
  end

  it "updates the latest fields when replace_latest swaps the upload" do
    u1 = fab_upload(filename: "r1.png")
    u1b = fab_upload(filename: "r1b.png")

    post endpoint, params: { upload_id: u1.id, note: "first" }
    expect(response.status).to eq(200)
    post endpoint, params: { upload_id: u1b.id, note: "corrected", mode: "replace_latest" }
    expect(response.status).to eq(200)

    topic.reload
    expect(topic.custom_fields[fields::REVISION_COUNT]).to eq(1)
    expect(topic.custom_fields[fields::LATEST_REVISION_UPLOAD_ID]).to eq(u1b.id)
    expect(topic.custom_fields[fields::LATEST_REVISION_IMAGE_URL]).to eq(u1b.url)

    images = topic.custom_fields[fields::REVISION_IMAGES]
    expect(images.length).to eq(1)
    expect(images.first).to include(
      "revision_number" => 1,
      "upload_id" => u1b.id,
      "note" => "corrected",
    )
  end
end
