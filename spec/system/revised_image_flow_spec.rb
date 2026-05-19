# frozen_string_literal: true

describe "Revised critique image flow" do
  fab!(:category)
  fab!(:owner) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) { Fabricate(:topic, category: category, user: owner) }
  fab!(:first_post) do
    Fabricate(
      :post,
      topic: topic,
      user: owner,
      raw: "Original image post body."
    )
  end

  before do
    enable_current_plugin
    SiteSetting.revised_critique_category_id = category.id
  end

  it "shows the banner above the posts only when a reply from another user exists" do
    sign_in(owner)

    visit "/t/#{topic.slug}/#{topic.id}"
    expect(page).to have_no_css(".revised-image-banner")

    Fabricate(:post, topic: topic, user: other_user, raw: "Feedback comment.")
    visit "/t/#{topic.slug}/#{topic.id}"
    expect(page).to have_css(".revised-image-banner")
    expect(page).to have_css(".revised-image-banner__message")
    expect(page).to have_css(".revised-image-banner__button")
  end

  it "does not show the banner to non-owners" do
    Fabricate(:post, topic: topic, user: other_user, raw: "Feedback comment.")
    sign_in(other_user)

    visit "/t/#{topic.slug}/#{topic.id}"
    expect(page).to have_no_css(".revised-image-banner")
  end

  it "opens the modal with the optional note field when the banner is clicked" do
    Fabricate(:post, topic: topic, user: other_user, raw: "Feedback comment.")
    sign_in(owner)

    visit "/t/#{topic.slug}/#{topic.id}"
    find(".revised-image-banner__button").click

    expect(page).to have_css(".revised-image-modal")
    expect(page).to have_css("#revised-image-note")
    expect(page).to have_css(".revised-image-modal__note-label")
  end
end
