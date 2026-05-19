# frozen_string_literal: true

describe DiscourseRevisedCritiqueImage::RevisionsController do
  fab!(:category)
  fab!(:owner) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) do
    Fabricate(
      :topic,
      category: category,
      user: owner,
      title: "Critique my image please"
    )
  end
  fab!(:first_post) do
    Fabricate(
      :post,
      topic: topic,
      user: owner,
      raw: "Original critique image post."
    )
  end
  fab!(:upload) do
    Fabricate(
      :upload,
      user: owner,
      original_filename: "revision.png",
      width: 800,
      height: 600
    )
  end

  let(:endpoint) { "/revised-critique-image/topics/#{topic.id}/revisions.json" }

  before do
    enable_current_plugin
    SiteSetting.revised_critique_category_id = category.id
  end

  context "as the OP" do
    before { sign_in(owner) }

    it "rejects when there are no replies from other users" do
      post endpoint, params: { upload_id: upload.id }

      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("no_replies")
      expect(
        topic.reload.custom_fields[
          DiscourseRevisedCritiqueImage::REVISED_IMAGE_UPLOAD_ID
        ]
      ).to be_blank
    end

    context "with a reply from another user" do
      before do
        Fabricate(
          :post,
          topic: topic,
          user: other_user,
          raw: "Some feedback for you."
        )
      end

      it "adds the revised image and appends the title marker" do
        post endpoint, params: { upload_id: upload.id }

        expect(response.status).to eq(200)
        topic.reload
        expect(
          topic.custom_fields[
            DiscourseRevisedCritiqueImage::REVISED_IMAGE_UPLOAD_ID
          ].to_i
        ).to eq(upload.id)
        expect(
          topic.custom_fields[
            DiscourseRevisedCritiqueImage::REVISED_IMAGE_ADDED_BY_USER_ID
          ].to_i
        ).to eq(owner.id)
        expect(topic.title).to eq("Critique my image please (+revised)")

        new_raw = first_post.reload.raw
        expect(new_raw).to include("## Revised Version")
        expect(new_raw).to include(upload.short_url)
        expect(new_raw).to include("## Original Version")
        expect(new_raw).to include("Original critique image post.")
        expect(new_raw).not_to include("**What changed:**")
      end

      it "respects a custom title marker" do
        SiteSetting.revised_critique_title_marker = "[REVISED]"
        post endpoint, params: { upload_id: upload.id }

        expect(response.status).to eq(200)
        expect(topic.reload.title).to eq("Critique my image please [REVISED]")
      end

      it "does not duplicate the marker when it is already present" do
        topic.update!(title: "Critique my image please (+revised)")

        post endpoint, params: { upload_id: upload.id }

        expect(response.status).to eq(200)
        expect(topic.reload.title).to eq("Critique my image please (+revised)")
      end

      it "skips the marker when it would exceed the title length limit" do
        SiteSetting.max_topic_title_length = topic.title.length + 2
        post endpoint, params: { upload_id: upload.id }

        expect(response.status).to eq(200)
        topic.reload
        expect(topic.title).to eq("Critique my image please")
        # Revision still applied.
        expect(
          topic.custom_fields[
            DiscourseRevisedCritiqueImage::REVISED_IMAGE_UPLOAD_ID
          ].to_i
        ).to eq(upload.id)
      end

      it "inserts the note when provided" do
        post endpoint,
             params: {
               upload_id: upload.id,
               note: "  Opened up the shadows.  "
             }

        expect(response.status).to eq(200)
        new_raw = first_post.reload.raw
        expect(new_raw).to include("**What changed:** Opened up the shadows.")
        expect(
          topic.reload.custom_fields[
            DiscourseRevisedCritiqueImage::REVISED_IMAGE_NOTE
          ]
        ).to eq("Opened up the shadows.")
      end

      it "collapses newlines inside a note to a single line" do
        post endpoint,
             params: {
               upload_id: upload.id,
               note: "Line one\n\nLine two"
             }

        expect(response.status).to eq(200)
        expect(first_post.reload.raw).to include(
          "**What changed:** Line one Line two"
        )
      end

      it "omits the note line cleanly when no note is given" do
        post endpoint, params: { upload_id: upload.id, note: "" }

        expect(response.status).to eq(200)
        expect(first_post.reload.raw).not_to include("**What changed:**")
      end

      it "rejects an over-length note" do
        SiteSetting.revised_critique_note_max_length = 10
        post endpoint, params: { upload_id: upload.id, note: "x" * 50 }

        expect(response.status).to eq(422)
        expect(response.parsed_body["error_key"]).to eq("note_too_long")
        expect(
          topic.reload.custom_fields[
            DiscourseRevisedCritiqueImage::REVISED_IMAGE_UPLOAD_ID
          ]
        ).to be_blank
      end

      it "rejects a second revision when replacement is disabled" do
        post endpoint, params: { upload_id: upload.id }
        expect(response.status).to eq(200)

        second_upload =
          Fabricate(
            :upload,
            user: owner,
            original_filename: "v2.png",
            width: 700,
            height: 500
          )
        post endpoint, params: { upload_id: second_upload.id }

        expect(response.status).to eq(422)
        expect(response.parsed_body["error_key"]).to eq("already_revised")
        expect(
          topic.reload.custom_fields[
            DiscourseRevisedCritiqueImage::REVISED_IMAGE_UPLOAD_ID
          ].to_i
        ).to eq(upload.id)
      end

      context "with replacement enabled" do
        before { SiteSetting.revised_critique_allow_replace = true }

        it "swaps the image and replaces the note cleanly" do
          post endpoint, params: { upload_id: upload.id, note: "First note." }
          expect(response.status).to eq(200)

          second_upload =
            Fabricate(
              :upload,
              user: owner,
              original_filename: "v2.png",
              width: 700,
              height: 500
            )
          post endpoint,
               params: {
                 upload_id: second_upload.id,
                 note: "Second note."
               }

          expect(response.status).to eq(200)
          raw = first_post.reload.raw
          expect(raw).to include(second_upload.short_url)
          expect(raw).not_to include(upload.short_url)
          expect(raw).to include("**What changed:** Second note.")
          expect(raw).not_to include("First note.")
        end

        it "removes the old note when replacement omits a note" do
          post endpoint, params: { upload_id: upload.id, note: "First note." }
          expect(response.status).to eq(200)

          second_upload =
            Fabricate(
              :upload,
              user: owner,
              original_filename: "v2.png",
              width: 700,
              height: 500
            )
          post endpoint, params: { upload_id: second_upload.id, note: "" }

          expect(response.status).to eq(200)
          raw = first_post.reload.raw
          expect(raw).not_to include("First note.")
          expect(raw).not_to include("**What changed:**")
        end

        it "does not append the marker a second time on replacement" do
          post endpoint, params: { upload_id: upload.id }
          expect(topic.reload.title).to eq(
            "Critique my image please (+revised)"
          )

          second_upload =
            Fabricate(
              :upload,
              user: owner,
              original_filename: "v2.png",
              width: 700,
              height: 500
            )
          post endpoint, params: { upload_id: second_upload.id }

          expect(response.status).to eq(200)
          expect(topic.reload.title).to eq(
            "Critique my image please (+revised)"
          )
        end
      end

      it "rejects when the topic is in another category" do
        topic.update!(category: Fabricate(:category))

        post endpoint, params: { upload_id: upload.id }

        expect(response.status).to eq(422)
        expect(response.parsed_body["error_key"]).to eq("not_in_category")
        expect(topic.reload.title).to eq("Critique my image please")
      end
    end
  end

  context "as a non-OP user" do
    before do
      Fabricate(:post, topic: topic, user: other_user, raw: "Feedback")
      sign_in(other_user)
    end

    it "is rejected and the title is unchanged" do
      post endpoint, params: { upload_id: upload.id }

      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("not_owner")
      expect(topic.reload.title).to eq("Critique my image please")
    end
  end

  context "as an anonymous user" do
    it "is rejected" do
      post endpoint, params: { upload_id: upload.id }
      expect(response.status).to eq(403)
    end
  end

  context "with security guards" do
    before do
      Fabricate(:post, topic: topic, user: other_user, raw: "Feedback")
      sign_in(owner)
    end

    it "rejects when the topic is closed" do
      topic.update!(closed: true)
      post endpoint, params: { upload_id: upload.id }
      expect(response.status).to eq(403)
      expect(response.parsed_body["error_key"]).to eq("cannot_edit_post")
    end

    it "rejects when the topic is archived" do
      topic.update!(archived: true)
      post endpoint, params: { upload_id: upload.id }
      expect(response.status).to eq(403)
      expect(response.parsed_body["error_key"]).to eq("cannot_edit_post")
    end

    it "rejects when the topic is deleted" do
      topic.trash!
      post endpoint, params: { upload_id: upload.id }
      expect(response.status).to eq(404)
    end

    it "rejects when the OP is suspended" do
      owner.update!(suspended_till: 1.day.from_now, suspended_at: Time.zone.now)
      post endpoint, params: { upload_id: upload.id }
      # Discourse's auth layer rejects suspended users with 403/not_logged_in
      # before we get to the controller body. Eligibility#suspended? is a
      # defence-in-depth check covering anywhere else the user could leak through.
      expect(response.status).to eq(403)
      expect(
        topic.reload.custom_fields[
          DiscourseRevisedCritiqueImage::REVISED_IMAGE_UPLOAD_ID
        ]
      ).to be_blank
    end

    it "rejects an SVG upload" do
      svg =
        Fabricate(
          :upload,
          user: owner,
          original_filename: "logo.svg",
          extension: "svg",
          width: 100,
          height: 100
        )
      post endpoint, params: { upload_id: svg.id }
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("invalid_upload")
    end

    it "rejects an upload that has no recorded dimensions" do
      no_dims =
        Fabricate(
          :upload,
          user: owner,
          original_filename: "weird.png",
          width: 0,
          height: 0
        )
      post endpoint, params: { upload_id: no_dims.id }
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("invalid_upload")
    end

    it "rate-limits non-staff after the configured threshold" do
      SiteSetting.revised_critique_allow_replace = true
      RateLimiter.enable
      freeze_time

      stub_const(
        DiscourseRevisedCritiqueImage::RevisionsController,
        :RATE_LIMIT_MAX,
        1
      ) do
        post endpoint, params: { upload_id: upload.id }
        expect(response.status).to eq(200)

        second_upload =
          Fabricate(
            :upload,
            user: owner,
            original_filename: "v2.png",
            width: 700,
            height: 500
          )
        post endpoint, params: { upload_id: second_upload.id }
        expect(response.status).to eq(429)
        expect(response.parsed_body["error_key"]).to eq("rate_limited")
      end
    ensure
      RateLimiter.disable
    end

    it "does not rate-limit staff users" do
      SiteSetting.revised_critique_allow_replace = true
      owner.update!(admin: true)
      RateLimiter.enable
      freeze_time

      stub_const(
        DiscourseRevisedCritiqueImage::RevisionsController,
        :RATE_LIMIT_MAX,
        1
      ) do
        post endpoint, params: { upload_id: upload.id }
        expect(response.status).to eq(200)

        second_upload =
          Fabricate(
            :upload,
            user: owner,
            original_filename: "v2.png",
            width: 700,
            height: 500
          )
        post endpoint, params: { upload_id: second_upload.id }
        expect(response.status).to eq(200)
      end
    ensure
      RateLimiter.disable
    end

    it "does not advertise success when PostRevisor reports a failed save" do
      allow_any_instance_of(PostRevisor).to receive(:revise!).and_return(false)
      post endpoint, params: { upload_id: upload.id }

      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("revision_failed")
      expect(
        topic.reload.custom_fields[
          DiscourseRevisedCritiqueImage::REVISED_IMAGE_UPLOAD_ID
        ]
      ).to be_blank
    end
  end
end
