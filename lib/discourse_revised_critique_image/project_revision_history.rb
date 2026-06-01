# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Read/write the ordered list of project revisions stored on a topic's
  # custom_fields. The original project submission (owned by
  # discourse-npn-submissions) is never touched — every revision is a
  # full project version appended after the original.
  #
  # Revision entry shape:
  #   {
  #     "revision_number" => 1,
  #     "created_at"      => "2026-06-15T14:30:00Z",
  #     "updated_at"      => "2026-06-15T14:30:00Z",
  #     "based_on"        => 0,                # 0 = original; otherwise prior rev #
  #     "user_id"         => 42,
  #     "note"            => "...",            # optional
  #     "images"          => [
  #       {
  #         "id"        => "stable-slot-id",
  #         "position"  => 1,                  # 1..N, normalised on save
  #         "upload_id" => 999,
  #         "short_url" => "upload://newhash.jpeg",
  #         "caption"   => "Optional caption",
  #         "alt"       => "Image 1",
  #         "status"    => "unchanged|replaced|new",
  #       },
  #       ...
  #     ],
  #   }
  class ProjectRevisionHistory
    MAX_IMAGES_HARD_LIMIT = 12

    def self.for(topic)
      new(topic)
    end

    def initialize(topic)
      @topic = topic
    end

    def entries
      @entries ||= load_entries
    end

    def count
      entries.size
    end

    def latest
      entries.last
    end

    def empty?
      entries.empty?
    end

    def at_max?
      count >= max
    end

    def max
      [SiteSetting.revised_critique_max_project_revisions.to_i, 1].max
    end

    def max_images
      raw = SiteSetting.revised_critique_max_project_images.to_i
      raw = MAX_IMAGES_HARD_LIMIT if raw <= 0 || raw > MAX_IMAGES_HARD_LIMIT
      raw
    end

    # Append a brand-new revision based on the previous latest (or the
    # original submission if no revisions exist yet). The caller passes a
    # normalized image array and the optional note; based_on is derived
    # from current history state.
    def add!(images:, user:, note:)
      now = Time.zone.now.iso8601
      entry = {
        "revision_number" => next_revision_number,
        "created_at" => now,
        "updated_at" => now,
        "based_on" => empty? ? 0 : entries.last["revision_number"].to_i,
        "user_id" => user.id,
        "note" => note.presence,
        "images" => normalize_images(images),
      }
      persist!(entries + [entry])
      entry
    end

    # Mutate the latest entry's images/note/user/updated_at while
    # preserving its revision_number, created_at, and based_on.
    def replace_latest!(images:, user:, note:)
      raise "no project revision to replace" if empty?

      latest_entry = entries.last.dup
      latest_entry["updated_at"] = Time.zone.now.iso8601
      latest_entry["user_id"] = user.id
      latest_entry["note"] = note.presence
      latest_entry["images"] = normalize_images(images)

      persist!(entries[0...-1] + [latest_entry])
      latest_entry
    end

    # Source-of-truth image array for any code that needs the latest
    # canonical view of the project — the latest revision if one exists,
    # else the original images from the submissions plugin payload.
    def latest_images(original_images:)
      latest ? Array(latest["images"]) : Array(original_images)
    end

    private

    def next_revision_number
      empty? ? 1 : (entries.last["revision_number"].to_i + 1)
    end

    # Trust callers to have validated upload IDs upstream; here we just
    # tidy the structure: re-number positions 1..N, dedupe by stable id
    # (first occurrence wins, matching the submissions plugin behaviour),
    # and coerce captions/alts to strings.
    def normalize_images(images)
      raise ArgumentError, "images must be an Array" unless images.is_a?(Array)

      seen_ids = {}
      Array(images)
        .map { |img| stringify_keys(img) }
        .each_with_index
        .filter_map do |img, _idx|
          stable_id = img["id"].to_s
          raise ArgumentError, "image missing stable id" if stable_id.blank?
          if seen_ids.key?(stable_id)
            raise ArgumentError, "duplicate image id #{stable_id} within revision"
          end
          seen_ids[stable_id] = true
          img
        end
        .each_with_index
        .map { |img, idx| img.merge("position" => idx + 1) }
        .map { |img| coerce_image_fields(img) }
    end

    def coerce_image_fields(img)
      {
        "id" => img["id"].to_s,
        "position" => img["position"].to_i,
        "upload_id" => img["upload_id"].to_i,
        "short_url" => img["short_url"].to_s,
        "caption" => img["caption"].to_s,
        "alt" => img["alt"].to_s.presence || "Image #{img["position"]}",
        "status" => normalize_status(img["status"]),
      }
    end

    def normalize_status(status)
      s = status.to_s
      %w[unchanged replaced new].include?(s) ? s : "new"
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end

    def persist!(new_entries)
      @entries = new_entries
      @topic.custom_fields[PROJECT_REVISIONS_KEY] = new_entries
      @topic.custom_fields[PROJECT_REVISIONS_SCHEMA_KEY] = PROJECT_REVISIONS_SCHEMA_VERSION
      @topic.save_custom_fields(true)
    end

    def load_entries
      raw = @topic.custom_fields[PROJECT_REVISIONS_KEY]
      return raw.dup if raw.is_a?(Array)
      []
    end
  end
end
