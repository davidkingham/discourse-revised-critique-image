# frozen_string_literal: true

# Browser coverage for the Phase 4 project revision editor. We exercise
# everything that doesn't require a real file upload (banner states,
# editor opening, card manipulation, save) and lean on the request
# spec for Add Image / Replace Image upload paths — system specs with
# headless file pickers are slow and brittle, and the upload plumbing
# itself is core Discourse behaviour rather than this plugin's logic.
describe "Project revision editor flow" do
  fab!(:category)
  fab!(:owner) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) do
    Fabricate(:topic, category: category, user: owner, title: "Project critique topic title")
  end

  fab!(:orig_upload_a) do
    Fabricate(:upload, user: owner, original_filename: "orig-a.jpeg", width: 800, height: 600)
  end
  fab!(:orig_upload_b) do
    Fabricate(:upload, user: owner, original_filename: "orig-b.jpeg", width: 800, height: 600)
  end

  let(:submission_type_key) { DiscourseRevisedCritiqueImage::SubmissionsCompat.submission_type_key }
  let(:data_key) { DiscourseRevisedCritiqueImage::SubmissionsCompat.project_data_key }
  let(:begin_marker) { DiscourseRevisedCritiqueImage::SubmissionsCompat.block_begin }
  let(:end_marker) { DiscourseRevisedCritiqueImage::SubmissionsCompat.block_end }

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
          "caption" => "Original A",
          "alt" => "Image 1",
        },
        {
          "id" => "slot-b",
          "position" => 2,
          "upload_id" => orig_upload_b.id,
          "short_url" => orig_upload_b.short_url,
          "caption" => "Original B",
          "alt" => "Image 2",
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
      raw: ["Intro text", begin_marker, "generated body", end_marker, "Closing"].join("\n\n"),
    )
  end

  before do
    enable_current_plugin
    SiteSetting.revised_critique_category_id = category.id
    SiteSetting.revised_critique_max_project_revisions = 2
    install_project_payload!
    install_first_post_with_markers!
    Fabricate(:post, topic: topic, user: other_user, raw: "Feedback comment.")
  end

  it "shows Revise Project to the OP before any project revisions" do
    sign_in(owner)
    visit "/t/#{topic.slug}/#{topic.id}"

    expect(page).to have_css(
      ".revised-image-banner[data-revised-image-banner-project-state='first']",
    )
    expect(page).to have_css(".revised-image-banner__primary")
    expect(page).to have_no_css(".revised-image-banner__secondary")
  end

  it "does not show the editor banner to non-OP viewers" do
    sign_in(other_user)
    visit "/t/#{topic.slug}/#{topic.id}"

    expect(page).to have_no_css(".revised-image-banner__primary")
  end

  it "shows Replace Latest + Add Another after one project revision (mixed)" do
    DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic).add!(
      images: [
        {
          "id" => "slot-a",
          "position" => 1,
          "upload_id" => orig_upload_a.id,
          "short_url" => orig_upload_a.short_url,
          "caption" => "rev1",
          "alt" => "Image 1",
          "status" => "unchanged",
        },
      ],
      user: owner,
      note: "first",
    )

    sign_in(owner)
    visit "/t/#{topic.slug}/#{topic.id}"

    expect(page).to have_css(
      ".revised-image-banner[data-revised-image-banner-project-state='mixed']",
    )
    expect(page).to have_css(".revised-image-banner__primary")
    expect(page).to have_css(".revised-image-banner__secondary")
  end

  it "shows only Replace Latest when at the project revision cap" do
    history = DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic)
    2.times do |i|
      history.add!(
        images: [
          {
            "id" => "slot-a",
            "position" => 1,
            "upload_id" => orig_upload_a.id,
            "short_url" => orig_upload_a.short_url,
            "caption" => "r#{i}",
            "alt" => "Image 1",
            "status" => "unchanged",
          },
        ],
        user: owner,
        note: "r#{i}",
      )
    end

    sign_in(owner)
    visit "/t/#{topic.slug}/#{topic.id}"

    expect(page).to have_css(
      ".revised-image-banner[data-revised-image-banner-project-state='atMax']",
    )
    expect(page).to have_css(".revised-image-banner__primary")
    expect(page).to have_no_css(".revised-image-banner__secondary")
  end

  describe "editor interactions" do
    before do
      sign_in(owner)
      visit "/t/#{topic.slug}/#{topic.id}"
      find(".revised-image-banner__primary").click
    end

    it "opens the editor and shows the original project images" do
      expect(page).to have_css(".project-revision-editor")
      expect(page).to have_css(".project-revision-editor__card", count: 2)
    end

    it "exposes a caption input on each card" do
      expect(page).to have_css(".project-revision-editor__card-caption-input", count: 2)
    end

    it "reorders cards via Move Right" do
      cards = page.all(".project-revision-editor__card", minimum: 2)
      first_id_before = cards[0]["data-card-id"]
      second_id_before = cards[1]["data-card-id"]

      within(cards[0]) { find(".project-revision-editor__card-move-right").click }

      cards_after = page.all(".project-revision-editor__card", minimum: 2)
      expect(cards_after[0]["data-card-id"]).to eq(second_id_before)
      expect(cards_after[1]["data-card-id"]).to eq(first_id_before)
    end

    it "removes a card with the Remove button" do
      within(page.all(".project-revision-editor__card").first) do
        find(".project-revision-editor__card-remove").click
      end
      expect(page).to have_css(".project-revision-editor__card", count: 1)
    end

    it "saves a first project revision using the existing baseline images" do
      # Edit the first caption so the assertion catches that the save
      # round-trip preserves the user's text, not just the upload ids.
      first_card = page.all(".project-revision-editor__card").first
      within(first_card) do
        input = find(".project-revision-editor__card-caption-input")
        input.set("Updated caption A")
      end
      find(".project-revision-editor__submit").click

      # The modal closes and the route refreshes; wait on a DB-side
      # signal (the persisted revision) rather than a UI race.
      try_until_success do
        history = DiscourseRevisedCritiqueImage::ProjectRevisionHistory.for(topic.reload)
        expect(history.count).to eq(1)
        expect(history.latest["images"].first["caption"]).to eq("Updated caption A")
      end
    end
  end
end
