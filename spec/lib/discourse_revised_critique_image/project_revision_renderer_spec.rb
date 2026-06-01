# frozen_string_literal: true

describe DiscourseRevisedCritiqueImage::ProjectRevisionRenderer do
  fab!(:owner, :user)

  def upload!(filename)
    Fabricate(:upload, user: owner, original_filename: filename, width: 800, height: 600)
  end

  def image(id:, upload:, caption: "")
    {
      "id" => id,
      "position" => 1, # caller chooses real positions; tests cover the rendered ordering
      "upload_id" => upload.id,
      "short_url" => upload.short_url,
      "caption" => caption,
      "alt" => "Image 1",
      "status" => "new",
    }
  end

  let(:upload_a) { upload!("orig-a.jpeg") }
  let(:upload_b) { upload!("rev-b.jpeg") }
  let(:upload_c) { upload!("rev-c.jpeg") }

  let(:original_data) do
    {
      "type" => "project_critique",
      "version" => 1,
      "images" => [image(id: "slot-1", upload: upload_a, caption: "Original caption")],
    }
  end

  describe "with no revisions" do
    it "renders the original expanded with no [details] wrappers" do
      output = described_class.render(original_data: original_data, revisions: [])
      expect(output).to include("### Project Overview")
      expect(output).to include("### Image Sequence")
      expect(output).not_to include("[details=")
    end
  end

  describe "with one revision" do
    let(:revisions) do
      [
        {
          "revision_number" => 1,
          "based_on" => 0,
          "images" => [image(id: "slot-1", upload: upload_b, caption: "Updated caption")],
        },
      ]
    end

    it "renders the latest revision expanded and the original in a [details] block" do
      output = described_class.render(original_data: original_data, revisions: revisions)

      latest_index = output.index("### Project Overview")
      original_details_index = output.index('[details="Original Submission"]')

      expect(latest_index).to be_a(Integer)
      expect(original_details_index).to be_a(Integer)
      expect(original_details_index).to be > latest_index

      expect(output).to include("Updated caption") # latest is expanded
      expect(output).to include("Original caption") # original lives in details
    end

    it "uses upload short_url in the image sequence" do
      output = described_class.render(original_data: original_data, revisions: revisions)
      expect(output).to include(upload_b.short_url)
      expect(output).to include(upload_a.short_url)
    end

    it "uses the real /uploads/ url in the overview HTML" do
      output = described_class.render(original_data: original_data, revisions: revisions)
      expect(output).to include(%(src="#{upload_b.url}"))
      expect(output).to include(%(class="npn-project-overview-image"))
    end
  end

  describe "with two revisions" do
    let(:revisions) do
      [
        {
          "revision_number" => 1,
          "based_on" => 0,
          "images" => [image(id: "slot-1", upload: upload_b)],
        },
        {
          "revision_number" => 2,
          "based_on" => 1,
          "images" => [image(id: "slot-1", upload: upload_c)],
        },
      ]
    end

    it "orders sections as: latest expanded, Revision 1, Original Submission" do
      output = described_class.render(original_data: original_data, revisions: revisions)

      latest_index = output.index("### Project Overview")
      rev1_index = output.index('[details="Revision 1"]')
      orig_index = output.index('[details="Original Submission"]')

      expect(latest_index).to be < rev1_index
      expect(rev1_index).to be < orig_index
    end

    it "wraps each older version in its own [details] / [/details] pair" do
      output = described_class.render(original_data: original_data, revisions: revisions)
      details_opens = output.scan("[details=").length
      details_closes = output.scan("[/details]").length
      # One for Revision 1, one for Original Submission. Latest is expanded.
      expect(details_opens).to eq(2)
      expect(details_closes).to eq(2)
    end
  end

  describe "when an upload referenced by an image was deleted" do
    let(:revisions) do
      [
        {
          "revision_number" => 1,
          "based_on" => 0,
          "images" => [image(id: "slot-1", upload: upload_b)],
        },
      ]
    end

    it "omits the overview cell rather than emitting a broken <img>" do
      upload_b.destroy!
      output = described_class.render(original_data: original_data, revisions: revisions)
      expect(output).not_to include(%(src="" alt="Image 1"))
      # Sequence still renders because short_url is in the stored entry.
      expect(output).to include(upload_b.short_url)
    end
  end
end
