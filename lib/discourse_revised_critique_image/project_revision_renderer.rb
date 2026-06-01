# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Renders the markdown that lives BETWEEN the
  # <!-- npn-project-submission:begin --> / :end markers. Composes:
  #
  #   1. The latest project version (revision or original) shown expanded.
  #   2. Any prior revisions in [details] blocks, newest-to-oldest.
  #   3. The original submission in a final [details] block, when at least
  #      one revision exists (otherwise the original IS the latest and is
  #      rendered expanded at the top instead).
  #
  # Each rendered version emits a "Project Overview" raw HTML grid (using
  # the same CSS classes the submissions plugin uses, so the existing
  # styling and allowlists carry over) and an "Image Sequence" markdown
  # list (so Discourse's lightbox + image optimisation work as usual).
  #
  # The renderer is pure data-in / string-out. It loads uploads once at
  # the start so the grid can render real `/uploads/` URLs (raw HTML
  # doesn't process `upload://`), but never mutates anything.
  class ProjectRevisionRenderer
    ORIGINAL_SECTION_LABEL = "Original Submission"

    def self.render(original_data:, revisions:)
      new(original_data: original_data, revisions: revisions).render
    end

    def initialize(original_data:, revisions:)
      @original_images = Array(original_data && original_data["images"])
      @revisions = Array(revisions)
      @uploads_by_id = preload_uploads
    end

    def render
      sections = []

      if @revisions.any?
        latest = @revisions.last
        sections << version_section(
          images: Array(latest["images"]),
          heading: nil, # expanded; no [details] wrapper
        )
        prior_revisions.reverse_each do |rev|
          sections << version_section(
            images: Array(rev["images"]),
            heading: label_for_revision(rev),
          )
        end
        if @original_images.any?
          sections << version_section(images: @original_images, heading: ORIGINAL_SECTION_LABEL)
        end
      else
        # No revisions yet: render the original expanded. This branch
        # exists for safety — adders always write the first revision
        # before calling render — but means the renderer is also usable
        # for a "preview the original" smoke test.
        sections << version_section(images: @original_images, heading: nil)
      end

      sections.compact.join("\n\n")
    end

    private

    # Revisions other than the latest one, in stored order (oldest first).
    # render walks them in reverse so the output is newest → oldest, then
    # the original last.
    def prior_revisions
      @revisions[0...-1] || []
    end

    def label_for_revision(rev)
      "Revision #{rev["revision_number"].to_i}"
    end

    def version_section(images:, heading:)
      return nil if Array(images).empty?

      body = [overview_grid(images), image_sequence(images)].compact.join("\n\n")
      if heading
        # Discourse's [details=…] supports HTML attributes only when quoted.
        # The label is content we control, so no user input reaches here,
        # but quote it anyway to keep the syntax robust against future
        # parser changes.
        "[details=\"#{heading}\"]\n#{body}\n[/details]"
      else
        body
      end
    end

    # Raw HTML matching the submissions plugin's existing CSS allowlist
    # (npn-project-overview-*) so all rendered versions share styling.
    # Falls back to omitting cells whose Upload was deleted rather than
    # emitting a broken <img> tag.
    def overview_grid(images)
      cells =
        images.each_with_index.flat_map do |img, index|
          label = "Image #{index + 1}"
          src = upload_url_for(img)
          next [] if src.blank?

          [
            '<div class="npn-project-overview-item">',
            %(<div class="npn-project-overview-label">#{escape_html(label)}</div>),
            '<div class="npn-project-overview-frame">',
            %(<img class="npn-project-overview-image" src="#{escape_html(src)}" alt="#{escape_html(label)}" loading="lazy">),
            "</div>",
            "</div>",
          ]
        end

      return nil if cells.empty?

      [
        "### Project Overview",
        "",
        '<div class="npn-project-overview-grid">',
        *cells,
        "</div>",
      ].join("\n")
    end

    # Markdown image list. `upload://` short URLs let Discourse swap in
    # optimized images and wire the lightbox; the **Image N** label keeps
    # the sequence aligned with the overview grid above.
    def image_sequence(images)
      blocks =
        images.each_with_index.flat_map do |img, index|
          label = "Image #{index + 1}"
          short_url = img["short_url"].to_s
          next [] if short_url.blank?

          parts = ["**#{label}**", "![#{label}](#{short_url})"]
          parts << "*#{img["caption"]}*" if img["caption"].to_s.strip.present?
          parts
        end

      return nil if blocks.empty?

      "### Image Sequence\n\n#{blocks.join("\n\n")}"
    end

    def upload_url_for(img)
      upload = @uploads_by_id[img["upload_id"].to_i]
      upload&.url.presence
    end

    def preload_uploads
      ids = collect_upload_ids
      return {} if ids.empty?
      Upload.where(id: ids).index_by(&:id)
    end

    def collect_upload_ids
      ids = @original_images.map { |i| i["upload_id"] }
      @revisions.each { |rev| ids.concat(Array(rev["images"]).map { |i| i["upload_id"] }) }
      ids.compact.map(&:to_i).uniq
    end

    def escape_html(value)
      ERB::Util.html_escape(value.to_s)
    end
  end
end
