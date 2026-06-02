# QA & maintenance checklist

Run-through for verifying the plugin end-to-end before promoting changes
to production. Designed to be copy-pasted into a PR or worklog and ticked
off live. Each item maps to a concrete observable behaviour in the code;
the **Verify** line is the exact thing you should check.

The detailed dependency map and rollback steps live in
[`MAINTENANCE.md`](./MAINTENANCE.md) and [`COMPATIBILITY.md`](./COMPATIBILITY.md);
this document is just the run-list.

Setup: a staging forum with this plugin and `discourse-npn-submissions`
both installed. Configure a category in `revised_critique_category_id`.
Have two TL1+ accounts ready: `op_user` and `feedback_user`. An admin
account is useful for the staff-only paths.

---

## 1. Single-image revisions

### First revision

- [ ] As `op_user`, create a topic with one image in the configured
      category. The banner does **not** appear (waiting on a reply).
      **Verify**: no `.revised-image-banner` element on the page.
- [ ] As `feedback_user`, post any reply. Reload as `op_user`. Banner
      appears with one primary button.
      **Verify**: `.revised-image-banner[data-revised-image-banner-state='first']`
      and `.revised-image-banner__primary` are present.
- [ ] Click the primary button. Modal opens, title is "Share a revised
      version". Upload an image. Submit.
      **Verify**: `/t/<slug>/<id>.json` shows
      `revised_critique_image_revision_count == 1` and
      `revised_critique_image.upload_id == <new id>`.
- [ ] First post body now shows a "Revised Version" section above an
      "Original Version" section, with the new image and (optional)
      "What changed" note.

### Add another revision

- [ ] After one revision exists, banner shows state `mixed`.
      **Verify**: two buttons present —
      `.revised-image-banner__primary` ("Replace Latest") and
      `.revised-image-banner__secondary` ("Add Another").
- [ ] Click "Add Another", upload, submit.
      **Verify**: history grows to 2 entries with strictly increasing
      `revision_number`. First post markdown renders both revisions,
      newest first.

### Replace latest

- [ ] Click "Replace Latest", upload a different image, optionally
      change the note, submit.
      **Verify**: `revised_critique_image_revision_count` did **not**
      increase. `revised_critique_image.updated_at` changed but
      `added_at` did not. The first post now references the new
      upload's `upload://` short URL.

### Max revisions

- [ ] Set `revised_critique_max_revisions = 2`. With two revisions
      already in place, reload the topic.
      **Verify**: banner shows state `atMax`. Only one button
      ("Replace Latest"). No secondary button.
- [ ] Replace Latest still works at the cap (replacing doesn't count
      toward `revised_critique_max_revisions`).

### Note field

- [ ] Submit a revision with a note. The note appears under
      "What changed:" in the first post markdown.
- [ ] Submit a revision with a note longer than
      `revised_critique_note_max_length` (set the setting to 10 to
      test quickly).
      **Verify**: client-side counter turns red, submit disabled;
      server-side returns 422 with `error_key: "note_too_long"`.

### Title marker

- [ ] On the first successful revision, the topic title gains the
      configured `revised_critique_title_marker` (default `(+revised)`).
- [ ] Subsequent revisions do **not** duplicate the marker.
      **Verify**: `topic.title.scan("(+revised)").length == 1`.
- [ ] If the title would exceed `max_topic_title_length` after adding
      the marker, the marker is **not** appended (no failure either —
      the revision still saves).

### Non-OP visibility

- [ ] Sign in as `feedback_user` (non-OP) on the same topic.
      **Verify**: no banner element on the page at all.
- [ ] Open `/t/<slug>/<id>.json` as `feedback_user`.
      **Verify**: `can_add_revised_critique_image == false`,
      `can_replace_latest_revised_critique_image == false`.
- [ ] Sign out entirely. Same expectation: no banner, both `can_*`
      booleans false (or fields absent for anon).

### Direct endpoint rejection

For each of these, hit
`POST /revised-critique-image/topics/<id>/revisions.json` from dev
tools and check the response.

- [ ] **Anonymous**: 403.
- [ ] **Non-OP**: 422 with `error_key: "not_owner"`.
- [ ] **Topic in a different category**: 422,
      `error_key: "not_in_category"`.
- [ ] **Topic is closed/archived/deleted**: 403,
      `error_key: "cannot_edit_post"`.
- [ ] **No reply from another user** (when
      `revised_critique_require_reply_from_other_user` is on): 422,
      `error_key: "no_replies"`.
- [ ] **Unknown mode**: 422, `error_key: "invalid_mode"`.
- [ ] **Missing `upload_id`**: 404, `error_key: "missing_upload"`.
- [ ] **SVG upload**: 422, `error_key: "invalid_upload"`.
- [ ] **Project topic** (npn_submission_type=project_critique): 422,
      `error_key: "project_topic_unsupported"` — the Phase 2.5 gate.

---

## 2. Project revisions

Setup specific to this section: have a topic created via
`discourse-npn-submissions` in the project-critique flow with ≥ 3
images. Confirm the topic has `npn_submission_type=project_critique`
and `npn_project_submission_data` in custom_fields, plus a
`<!-- npn-project-submission:begin --> ... :end -->` block in the
first post.

### First project revision

- [ ] As `op_user`, with at least one reply from `feedback_user`
      present, banner shows the project state `first`.
      **Verify**:
      `.revised-image-banner[data-revised-image-banner-project-state='first']`
      with one button labelled "Revise Project".
- [ ] Click "Revise Project". Modal "Revise project" opens. All
      original images appear as cards, in original position order.
      **Verify**: count of `.project-revision-editor__card` matches
      the original image count.
- [ ] Add a note in the textarea. Click "Save revision".
      **Verify**: response is 200; `project_revision_count == 1`.
      Modal closes; the topic refreshes; the first post body between
      the `<!-- npn-project-submission:begin/end -->` markers is
      re-rendered with the new project overview + image sequence.
      Original submission now appears in a collapsed `[details]` block.

### Add another project revision

- [ ] After one project revision exists, banner shows project state
      `mixed`. Two buttons: "Replace Latest Project Revision" and
      "Add Another Project Revision".
- [ ] Click "Add Another". Modal opens, pre-loaded with the **latest
      revision's** images and an empty note.
      **Verify**: cards match `history.latest.images`.
- [ ] Submit. `project_revision_count == 2`,
      `history.latest.based_on == 1`.

### Replace latest project revision

- [ ] Click "Replace Latest". Modal opens, pre-loaded with latest
      images **and** the latest revision's note (since this is an
      in-place edit).
- [ ] Make any change, submit.
      **Verify**: `project_revision_count` did **not** increase.
      `history.latest.updated_at` changed but `created_at` did not.

### Reorder with Move Left / Move Right

- [ ] Open the editor on a project with ≥ 2 images. Click the second
      card's "Move left". Card order in the editor swaps.
      **Verify**: cards' `data-card-id` values swap in DOM order.
- [ ] First card's "Move left" is disabled. Last card's "Move right"
      is disabled. **Verify**: the buttons render disabled (greyed).
- [ ] Save. Reload the editor.
      **Verify**: the new order persisted (positions normalised to
      1..N).

### Remove image from revised project

- [ ] On a project with ≥ 2 images, click "Remove" on one card. The
      card disappears from the editor.
- [ ] On a project where the editor now has exactly **one** image,
      "Remove" is disabled — the editor refuses to enter an unsavable
      state. **Verify**: button is disabled; clicking again does
      nothing.
- [ ] Save. Server accepts. `history.latest.images.length` matches
      what's in the editor.
- [ ] **No Upload was deleted** — the removed image's upload still
      exists in `Upload.find(<id>)`. We only drop it from this
      revision.

### Edit captions

- [ ] Type into a card's caption input. Save.
      **Verify**: the caption persists in `history.latest.images[i].caption`
      and renders below the image in the "Image Sequence" section of
      the first post markdown.
- [ ] Empty captions are stored as `""` (not omitted, not null).

### Save note

- [ ] Type a note in the textarea. Save.
      **Verify**: `history.latest.note` matches what you typed,
      stripped of leading/trailing whitespace.
- [ ] Submit a revision with no note. `history.latest.note` is `nil`.

### Max 12 images

- [ ] Set `revised_critique_max_project_images = 3`. Open the editor
      on a topic with 3+ original images.
      **Verify**: the "Add image" button is disabled (you can't go
      higher than the cap).
- [ ] Force a higher count via the API directly — should be rejected.
      `POST .../project-revisions` with 4 images returns 422,
      `error_key: "too_many_images"`.
- [ ] Reset the setting and confirm: the hard 12 cap still applies
      regardless of how the setting is set (handled both client- and
      server-side in `ProjectRevisionHistory::MAX_IMAGES_HARD_LIMIT`).

### Fewer than original images

- [ ] Open the editor on a 3-image project. Remove one card. Save.
      **Verify**: `history.latest.images.length == 2`. The first
      post markdown renders 2 images in the new "Project Overview"
      grid and "Image Sequence" — no "ghost slot" for the dropped one.

### Original project collapsed

- [ ] After at least one revision, view the topic as anyone.
      **Verify**: the first post markdown contains
      `[details="Original Submission"]` wrapping the original images.

### Older revisions collapsed

- [ ] After two revisions, the first post contains
      `[details="Revision 1"]` wrapping Revision 1.
- [ ] After three revisions, both `[details="Revision 1"]` and
      `[details="Revision 2"]` are present, ordered newest → oldest
      → original.

### Latest revision expanded

- [ ] In all cases above, the **newest** revision renders with bare
      `### Project Overview` + `### Image Sequence` headings — **no**
      `[details]` wrapper around it.

### User-authored text outside markers preserved

- [ ] Add user text BEFORE the
      `<!-- npn-project-submission:begin -->` marker and AFTER the
      `:end -->` marker in the first post raw.
- [ ] Submit a project revision.
      **Verify**: `topic.first_post.reload.raw` has the prefix and
      suffix text **byte-identical** to before — only the slice
      between markers changed.

---

## 3. Edge cases

### Closed topic

- [ ] Close the topic. Reload as OP.
      **Verify**: no banner. JSON: `can_add_revised_critique_image` /
      `can_add_project_revision` both `false`.
- [ ] Direct POST: 403, `error_key: "cannot_edit_post"`.

### Archived topic

- [ ] Archive the topic. Same expectations as closed.

### Deleted/missing markers

- [ ] On a project topic, manually remove the
      `<!-- npn-project-submission:begin -->` marker from the first
      post raw via admin.
      **Verify**: the banner shows the staff-only "Project revision
      tools are coming soon." fallback (no action buttons), since
      `reader.valid?` is false → `ProjectEligibility` refuses.
- [ ] Direct POST: 422, `error_key: "project_data_invalid"`.
- [ ] Verify **no** mutation occurred — `first_post.raw` and
      `history.count` both unchanged.

### Malformed project data

- [ ] Manually corrupt `npn_project_submission_data` (e.g. set to
      `"junk"` via rails console) on a project-tagged topic.
      **Verify**: the Phase 2.5 tag-based gate still blocks
      single-image revisions (since the project tag is one of three
      signals). Project flow refuses with `project_data_invalid`.
      Banner falls back to "coming soon" for OP/staff only.

### Invalid upload

- [ ] POST a revision with a non-existent `upload_id`. Single-image:
      404, `missing_upload`. Project:
      `error_key: "invalid_image_payload"` (422).
- [ ] Upload an Upload row with `width: 0` or `height: 0` (e.g. via
      direct DB tweak): both flows reject with `invalid_upload` /
      `invalid_image_payload` server-side via `ImageUploadValidation`.

### SVG upload

- [ ] Upload an `.svg` file via the modal.
      **Verify**: client-side, the uploader may accept it; the
      server-side reject is the gate.
      Single-image: 422, `invalid_upload`.
      Project: 422, `invalid_image_payload`.

### Rate limit

- [ ] As a non-staff OP, set
      `RevisionsController::RATE_LIMIT_MAX = 1` (or run a quick
      sequence). The 2nd revision within an hour returns 429,
      `error_key: "rate_limited"`.
- [ ] Same for project revisions on a separate rate-limit key:
      `revised-critique-project-revision`.
- [ ] Admin/staff bypass: both endpoints accept unlimited.

### Mobile/narrow viewport

- [ ] Resize browser to ≤ 640px (Discourse's mobile breakpoint).
      Open the project editor.
      **Verify**: cards collapse from 2-column (thumb + meta) to a
      single-column layout. All buttons remain visible and tappable
      without overflow.
- [ ] Repeat for the single-image modal — the existing layout has no
      cards and stays compact.
- [ ] On mobile real-device test: scrolling inside the modal body
      works; the footer with Save / Cancel stays pinned and visible.

### Dark mode

- [ ] Switch the user's color scheme to a dark one. Open the editor.
      **Verify**: the editor uses the
      `--primary` / `--primary-very-low` / `--secondary` tokens, so
      it inherits dark colours. Card borders should remain visible
      (not invisible-on-invisible). Caption inputs readable.

### S3/CDN upload URLs

- [ ] On a forum configured with S3 + a CDN (or local with
      `enable_s3_uploads` and a fake CDN config), submit a project
      revision.
      **Verify**: image `<img src=...>` URLs in the rendered post
      use the CDN host (matches what Discourse normally emits).
      `Upload.short_url` round-trips through the cook process
      regardless.
- [ ] Run the secure-uploads test: a fresh upload referenced for the
      first time in the first post should get its
      `access_control_post_id` set to the OP's post id, making it
      visible to other authorised users. See
      `app/models/concerns/has_post_upload_references.rb` upstream.

---

## 4. Deployment checklist

### Plugin settings

- [ ] `revised_critique_enabled` — confirm `true` in production.
- [ ] `revised_critique_category_id` — set to the **production**
      category id. Different from staging.
- [ ] `revised_critique_max_revisions` — confirm value (default 3).
- [ ] `revised_critique_max_project_revisions` — confirm value
      (default 3, min 1).
- [ ] `revised_critique_max_project_images` — confirm value
      (default 12, hard-capped at 12).
- [ ] `revised_critique_note_max_length` — confirm value
      (default 500).
- [ ] `revised_critique_title_marker` — confirm string (default
      `(+revised)`); blank to disable.
- [ ] `revised_critique_require_reply_from_other_user` — confirm
      boolean (default true).
- [ ] `revised_critique_add_notice_reply` — confirm boolean
      (default false). If enabling, also confirm
      `revised_critique_notice_reply_username` is a valid user.

### Required submissions plugin version/commit

- [ ] `discourse-npn-submissions` must be installed for Phase 2+
      project detection and editor baselines to function.
- [ ] Required constants (verify by Rails console after deploy):
      ```ruby
      defined?(DiscourseNpnSubmissions::TopicMetadata::PROJECT_SUBMISSION_DATA_KEY)
      defined?(DiscourseNpnSubmissions::ProjectPostBuilder::PROJECT_BLOCK_BEGIN)
      defined?(DiscourseNpnSubmissions::ProjectPostBuilder::PROJECT_BLOCK_END)
      ```
      All should return truthy. The plugin falls back to documented
      literal strings if missing, but the canonical constants are
      preferred.
- [ ] If you pin a specific submissions plugin commit/tag in
      production, note it here when deploying so a future rollback
      knows the matching pair.

### CI status

- [ ] Latest commit on `main` shows a green check at
      `https://github.com/davidkingham/discourse-npn-revised-critique/actions`.
- [ ] The weekly scheduled run is also green (catches upstream
      Discourse regressions even when the plugin itself hasn't
      changed).
- [ ] If CI is red, **do not deploy** — fix forward or pin to the
      last green commit (see rollback below).

### Rollback plan

- [ ] Know the last-known-good plugin commit SHA. Easiest to capture
      from the green CI run timestamp.
- [ ] Pin in `app.yml` if needed (see
      [`MAINTENANCE.md`](./MAINTENANCE.md) → "Rollback steps" for the
      exact `git checkout` snippet).
- [ ] Rebuild: `cd /var/discourse && ./launcher rebuild app`.
- [ ] If the issue is data corruption (markers stripped, malformed
      JSON), use the rails console snippets in `MAINTENANCE.md` to
      strip the revision block / clear custom_fields per topic.

### Known fragile dependencies

The full table is in
[`MAINTENANCE.md`](./MAINTENANCE.md) → "Fragile integration points",
but the top of mind risks are:

- [ ] **`topic-above-posts` plugin outlet** — if Discourse renames or
      removes this outlet, the banner vanishes silently.
- [ ] **`discourse/ui-kit/d-modal` + `d-button` + `d-modal-cancel`**
      — recent move from `discourse/components/...`. Another rename
      is plausible.
- [ ] **`UppyImageUploader` + `UppyUpload`** — uploader internals
      change occasionally; watch for `@onUploadDone` payload shape
      drift (`.id` / `.url` / `.short_url` keys).
- [ ] **`PostRevisor.revise!` flag set** (`skip_validations`,
      `bypass_bump`, `skip_revision`) — used in both single-image and
      project flows; flag renames would silently break edits.
- [ ] **`TopicViewSerializer.prepend`** — if upstream moves to a
      contract serializer, the prepend stops adding attributes and
      the banner stops appearing for everyone.
- [ ] **`Upload#short_url` + secure-upload `access_control_post_id`
      semantics** — broken images for non-OP viewers if the contract
      changes.
- [ ] **Project markers**
      (`<!-- npn-project-submission:begin/end -->`) — owned by the
      submissions plugin; renaming there would silently break
      project revisions (rejected with `project_data_invalid`).

When upstream changes one of these, prefer adapting our call site
over rebuilding the feature — every line of compatibility shim is a
future bug.
