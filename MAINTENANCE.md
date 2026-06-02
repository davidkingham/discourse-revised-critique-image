# Maintenance

Reference for keeping the plugin healthy as Discourse evolves. Pair this
with [`QA-CHECKLIST.md`](./QA-CHECKLIST.md) (the run-list) and
[`COMPATIBILITY.md`](./COMPATIBILITY.md) (the fragility map and manual
regression checklist).

This file is current through **Phase 4** (project revision editor). The
plugin now exposes two parallel revision flows — single-image (the
original v1/v2 feature) and project (added in Phase 3, with editor UI in
Phase 4) — and the storage / endpoint / renderer surface for each is
documented below.

---

## Custom fields

All of these live on `topic_custom_fields`. Owned-by columns matter
because some keys are owned by the sibling `discourse-npn-submissions`
plugin and **must not** be written by this plugin.

| Key | Type | Owner | Purpose |
|---|---|---|---|
| `revised_image_history` | `:json` | this plugin | Source-of-truth single-image revision array; each entry is `{revision_number, upload_id, upload_short_url, width, height, note, user_id, created_at, updated_at}`. |
| `revised_image_upload_id` | `:integer` | this plugin | Denormalised pointer to the latest single-image revision's upload. |
| `revised_image_added_at` | `:string` | this plugin | Denormalised latest-revision timestamp (ISO 8601). |
| `revised_image_added_by_user_id` | `:integer` | this plugin | Denormalised latest-revision user id. |
| `revised_image_note` | `:string` | this plugin | Denormalised latest-revision note. |
| `npn_revision_count` | `:integer` | this plugin | NPN-namespaced count, consumed by `discourse-npn-critique-reply`. |
| `npn_latest_revision_upload_id` | `:integer` | this plugin | NPN-namespaced latest upload id. |
| `npn_latest_revision_image_url` | `:string` | this plugin | NPN-namespaced latest upload URL. |
| `npn_revision_images` | `:json` | this plugin | NPN-namespaced array of all revision images. |
| `npn_critique_image_version_schema` | `:integer` | this plugin | NPN schema version stamp (currently `1`). |
| `npn_project_revisions` | `:json` | **this plugin** | Phase 3 project revision array. See below. |
| `npn_project_revisions_schema` | `:integer` | **this plugin** | Phase 3 schema version (currently `1`). |
| `npn_project_submission_data` | `:json` | **submissions plugin** | Immutable original project payload. **Never** written by this plugin — we defensively co-register it as `:json` so it round-trips correctly when running this plugin's CI standalone, but writes belong to the submissions plugin. |
| `npn_submission_type` | `:string` | **submissions plugin** | `"image_critique"` / `"weekly_challenge"` / `"project_critique"`. Read-only here. |

### `npn_project_revisions` entry shape

```ruby
{
  "revision_number" => 1,
  "created_at"      => "2026-06-15T14:30:00Z",
  "updated_at"      => "2026-06-15T14:30:00Z",
  "based_on"        => 0,            # 0 = original; otherwise prior rev #
  "user_id"         => 42,
  "note"            => "Optional note describing this round",
  "images"          => [
    {
      "id"        => "stable-slot-id",   # 16-char hex from submissions, or new-<ts>-<n> when added in editor
      "position"  => 1,                  # 1..N, normalised on save
      "upload_id" => 999,
      "short_url" => "upload://newhash.jpeg",
      "caption"   => "Optional caption",
      "alt"       => "Image 1",
      "status"    => "unchanged|replaced|new",
    },
    ...
  ],
}
```

Storage rules enforced in `ProjectRevisionHistory#normalize_images`:
- positions re-numbered 1..N on every save (drop input ordering noise);
- ids must be present (auto-generated `SecureRandom.hex(8)` if blank);
- duplicate ids within a revision raise `ArgumentError`;
- captions coerced to `String`; alt falls back to `"Image #{position}"`.

### `revised_image_history` entry shape

See `lib/discourse_revised_critique_image/revision_history.rb:6-17`.
Same row docs the legacy fields. The denormalised scalars
(`revised_image_upload_id`, etc.) always point at the **last** entry
in this array.

---

## Endpoints

Both endpoints live under the `/revised-critique-image` mount point.

### `POST /revised-critique-image/topics/:topic_id/revisions`

Single-image flow. Used by the original "Share Revised Version" / "Add
Another Revision" / "Replace Latest Revision" buttons.

| Param | Required | Notes |
|---|---|---|
| `upload_id` | yes | Must point to an `Upload` that passes `ImageUploadValidation` (raster image, positive width/height, not SVG). |
| `note` | no | String. Length-capped by `revised_critique_note_max_length`. |
| `mode` | no | `"add"` (default) or `"replace_latest"`. |

Auth: `ensure_logged_in`. Eligibility: `Eligibility.check` (owner,
category, not closed/archived, first post editable, optional reply
gate, max-revisions for `add`, project-topic gate refuses
`project_critique` topics). Rate limit: 6/hour per non-staff user,
key `revised-critique-image`.

Errors return `{ errors: [...], error_key: <symbol_as_string> }` with
status 422/403/404/429 depending on the cause. See the i18n keys at
`config/locales/server.en.yml` under
`discourse_revised_critique_image.errors`.

### `POST /revised-critique-image/topics/:topic_id/project-revisions`

Project flow. Used by the Phase 4 project editor.

| Param | Required | Notes |
|---|---|---|
| `mode` | no | `"add"` (default) or `"replace_latest"`. |
| `note` | no | String. Same length cap as single-image. |
| `images` | yes | Array of `{ id, upload_id, caption }`. `id` may be a stable slot id (from the original or a prior revision) or any new value the editor generated. The server normalises positions and re-derives `short_url` / `alt` from the upload. |

Auth: `ensure_logged_in`. Eligibility: `ProjectEligibility.check`
(owner, category, **must** be a project topic, project payload valid,
markers present, max-project-revisions for `add`, history non-empty
for `replace_latest`). Rate limit: 6/hour per non-staff user, key
`revised-critique-project-revision`.

Returns `{ topic_id, mode, revision_number, image_count }` on 200.

---

## Serializer fields

All exposed on `TopicViewSerializer` via
`lib/extensions/topic_view_serializer_extension.rb`. Phase 4 added the
last group.

### Single-image (Phase 1/2)

| Field | Visible to | Source |
|---|---|---|
| `revised_critique_image` | everyone | `RevisionHistory.latest` |
| `revised_critique_image_revision_count` | everyone | `RevisionHistory.count` |
| `revised_critique_image_max_revisions` | everyone | `RevisionHistory.max` |
| `can_add_revised_critique_image` | everyone (false for guests) | `Eligibility.check(... :add)` |
| `can_replace_latest_revised_critique_image` | everyone | `Eligibility.check(... :replace_latest)` |

### Project detection (Phase 2)

| Field | Visible to | Source |
|---|---|---|
| `revised_critique_revision_type` | everyone | `"project"` if `ProjectSubmissionReader.project?` else `"single_image"` |
| `revised_critique_project_detected` | everyone | `reader.project?` |
| `revised_critique_project_valid` | everyone | `reader.valid?` |
| `revised_critique_project_image_count` | everyone | `reader.image_count` |
| `revised_critique_project_error_key` | **staff only** | `reader.error_key` for diagnostics; `nil` for normal members |

### Project revisions (Phase 3/4)

| Field | Visible to | Source |
|---|---|---|
| `project_revision_count` | everyone | `ProjectRevisionHistory.count` |
| `project_revision_max_revisions` | everyone | site setting |
| `project_revision_max_images` | everyone | site setting (hard-capped at 12) |
| `can_add_project_revision` | everyone (false for guests) | `ProjectEligibility.check(... :add)` |
| `can_replace_latest_project_revision` | everyone | `ProjectEligibility.check(... :replace_latest)` |
| `project_revision_editor` | **OP/staff with edit rights only** | `{ original: {images, note}, latest: {images, note} }` — full editor baseline; each image carries `id / upload_id / short_url / image_url / caption / alt`. Returns `nil` for users without edit rights so normal members never receive image URLs they don't need. |

---

## Marker behaviour

The plugin uses **two unrelated marker pairs**. Don't confuse them.

### Single-image markers (this plugin owns)

```
<!-- revised-critique-image:begin -->
...auto-generated revision block...
<!-- revised-critique-image:end -->

## Original Version

...the rest of the original first-post body...
```

Defined in `RevisionAdder::BEGIN_MARKER` / `END_MARKER`. The block is
fully regenerated on every revision; user-authored text outside the
markers (specifically, before them — the original body lives BELOW the
block under an "Original Version" heading) is preserved.

### Project markers (submissions plugin owns)

```
<!-- npn-project-submission:begin -->
...project overview + image sequence + collapsed older versions...
<!-- npn-project-submission:end -->
```

Defined upstream in
`DiscourseNpnSubmissions::ProjectPostBuilder::PROJECT_BLOCK_BEGIN` /
`PROJECT_BLOCK_END`. We resolve them via
`DiscourseRevisedCritiqueImage::SubmissionsCompat`, which prefers the
sibling plugin's constants when defined and falls back to the
documented literal strings when not (so this plugin's own standalone
CI works without the submissions plugin loaded).

User-authored text outside these markers is preserved byte-for-byte
across project revisions — `ProjectRevisionAdder#splice_between_markers`
replaces only the slice between markers and never touches the prefix
or suffix.

### What renders inside the project markers

`ProjectRevisionRenderer.render` produces, in order:

1. **Latest version** (or original, if no revisions yet) — expanded.
   `### Project Overview` (raw-HTML grid) + `### Image Sequence`
   (markdown images with optional captions).
2. **Prior revisions**, newest-to-oldest, each in
   `[details="Revision N"]`.
3. **Original Submission** in `[details="Original Submission"]` (only
   when at least one revision exists).

The overview grid uses the same `npn-project-overview-*` CSS classes
the submissions plugin allowlists, so styling carries over. Deleted
uploads are skipped at render time (no broken `<img>` tags).

---

## PostRevisor usage

Both adders call `PostRevisor.new(first_post, topic).revise!(user, ...)`
with the same flag set:

```ruby
revise!(
  user,
  { raw: new_raw, title: title_with_marker_or_nil },
  skip_validations: true,
  bypass_bump: true,
  skip_revision: false,
)
```

Flag rationale:

- **`skip_validations: true`** — the OP's body may legitimately be
  very short (e.g. just an image), which would otherwise trip
  min-body-length validations. Authorization is enforced upstream by
  `Eligibility` / `ProjectEligibility` and double-checked in the
  controller via `Guardian#can_edit?`.
- **`bypass_bump: true`** — revising an image shouldn't surface the
  topic in "Latest" again. Replies still bump.
- **`skip_revision: false`** — we DO want a `PostRevision` row so the
  edit history is auditable in the post wrench menu.

### Atomicity (Phase 3 hardening)

Both `RevisionAdder#call` and `ProjectRevisionAdder#call` wrap the
write phase in `Topic.transaction`:

```ruby
Topic.transaction do
  apply_history_change!   # writes custom_fields via save_custom_fields
  saved = PostRevisor.new(...).revise!(...)
  raise ActiveRecord::Rollback unless saved
end
```

If `revise!` returns false (refusal) or raises, the transaction rolls
back, undoing the JSON history write too. **Known limitation**: any
Sidekiq enqueue performed from a plain `after_save` callback (rather
than `after_commit`) still fires even on rollback. Discourse's
first-party post-edit callbacks all use `after_commit`, so the corner
case is narrow — but the failure mode is "post body unchanged, but a
job fired thinking it was changed", and you should be aware of it
when investigating any phantom-event reports.

`maybe_post_notice_reply!` (single-image only) runs **outside** the
transaction by design — a notice failure shouldn't unwind an
otherwise-successful revision.

---

## UppyImageUploader / UppyUpload usage

Three different upload integration points across the plugin. Two use
`UppyImageUploader` as a visible component; one uses `UppyUpload`
programmatically.

### Single-image modal (`modal/revised-image-modal.gjs`)

One `UppyImageUploader` per modal instance. Args:

```gjs
<UppyImageUploader
  @id="revised-image-uploader"
  @type="revised_critique_image"
  @imageUrl={{this.uploadedImageUrl}}
  @onUploadDone={{this.onUploadDone}}
  @onUploadDeleted={{this.onUploadDeleted}}
/>
```

The `@onUploadDone` callback receives an upload object with `.id`,
`.url`, `.short_url`. We capture `id` for the API submit and `url`
for the in-modal preview.

### Project editor (`modal/project-revision-editor.gjs`)

**ONE shared `UppyUpload`** instance + ONE hidden `<input type="file">`
handle every upload in the editor — both "Add image" and per-card
"Replace". This was a Phase 4 rebuild: the first cut had a
`UppyImageUploader` per card, which created visual clutter (native
"Change" + "Delete" buttons), id-keyed `appEvents` collisions, and
made testing brittle.

Pattern:

```js
uppyUpload = new UppyUpload(getOwner(this), {
  id: "project-revision-editor",
  type: "revised_critique_image",
  validateUploadedFilesOptions: { imagesOnly: true },
  uploadDone: (upload) => this.routeUpload(upload),
});

// Wired to the file input via {{didInsert this.registerFileInput}}
@action registerFileInput(element) { this.uppyUpload.setup(element); }

// Buttons set an intent then trigger the picker
@action triggerAdd()      { this.nextUploadTarget = { kind: "add" }; this.uppyUpload.openPicker(); }
@action triggerReplace(id) { this.nextUploadTarget = { kind: "replace", id }; this.uppyUpload.openPicker(); }

// One sink routes by intent
routeUpload(upload) {
  const target = this.nextUploadTarget || { kind: "add" };
  this.nextUploadTarget = null;
  // ... append or swap card ...
}
```

The hidden file input is **visually hidden but not `display:none`** —
Uppy needs it attached to the DOM:

```scss
.project-revision-editor__file-input {
  position: absolute;
  width: 1px;
  height: 1px;
  opacity: 0;
  pointer-events: none;
}
```

### Other watch-outs for UppyImageUploader / UppyUpload

- The `@onUploadDone` payload shape (`.id`, `.url`, `.short_url`,
  `.width`, `.height`) is stable but has shifted in past Discourse
  releases. Verify all five fields in the upload object if behaviour
  changes after a core update.
- `UppyUpload`'s `id:` is also used internally as an `appEvents` event
  namespace. Two instances with the same id will cross-fire on
  uploads. Always use a literal unique id per editor instance.
- `validateUploadedFilesOptions: { imagesOnly: true }` is the
  client-side filter; the **authoritative** image check is server-side
  via `ImageUploadValidation`. Don't rely on the client to gate SVGs.

---

## Known limitations

1. **Sidekiq jobs from `after_save` leak on transaction rollback.** Both
   atomic adders wrap their write phase in `Topic.transaction`, but any
   side-effect callback that enqueues a Sidekiq job from `after_save`
   (rather than `after_commit`) will still fire even when the
   transaction rolls back. Discourse's first-party post-edit callbacks
   use `after_commit`, so the corner case is narrow.

2. **In-memory `Topic#custom_fields` pollution after rollback.** When a
   write rolls back, the DB is restored but the in-memory
   `@topic.custom_fields` Hash on the failing request retains the
   pre-rollback assignments. The next request gets a fresh load and
   clean state, so this is per-request only — but tests should always
   `topic.reload` before inspecting custom_fields after a failure.

3. **`image_url` in the project editor baseline is the full-size
   upload URL.** No optimised thumbnail. A project critique with many
   large images downloads several full files when the editor opens.
   Acceptable at the current cap of 12 images, but worth swapping to
   `mini_url` (Discourse's optimised variant) if usage grows.

4. **Deleted upstream uploads degrade silently.** If an `Upload` row
   referenced by a saved project revision gets destroyed, the
   renderer skips the overview cell (no broken `<img>`) but the
   markdown sequence still emits the `upload://` short URL — Discourse
   surfaces that as a broken image link. There's no rebuild flow to
   replace deleted uploads from within a revision.

5. **The 12-image hard cap is enforced both server-side
   (`ProjectRevisionHistory::MAX_IMAGES_HARD_LIMIT`) and via the site
   setting validator** (`max: 12` on
   `revised_critique_max_project_images`). The settings UI rejects
   values above 12; raising the cap requires a code change.

6. **CI runs against Discourse `main` only.** Stable Discourse isn't
   tested. The production site tracks tests-passed, so this is
   intentional, but if you ever want to support stable, see the
   workflow's banner comment for what to flip.

7. **No backwards-compatibility shims for the
   `discourse-npn-submissions` plugin's constants.** This plugin
   prefers the canonical constants and falls back to documented
   literal strings if the sibling plugin is unloaded — but it doesn't
   know about constant **renames**. If the submissions plugin renames
   `PROJECT_SUBMISSION_DATA_KEY` etc., this plugin breaks until the
   `SubmissionsCompat` fallbacks are updated.

8. **The project editor doesn't have undo.** Removing a card is
   immediate; closing the modal without saving discards changes. There
   is no autosave / draft state.

---

## Running specs locally

```bash
# Request specs (controllers + services + security guards)
bin/rspec plugins/discourse-npn-revised-critique/spec/requests/

# Unit / service specs (history, renderer, reader, eligibility, compat)
bin/rspec plugins/discourse-npn-revised-critique/spec/lib/

# Serializer specs
bin/rspec plugins/discourse-npn-revised-critique/spec/serializers/

# System specs (banner visibility + editor flow, needs Playwright)
bin/rspec plugins/discourse-npn-revised-critique/spec/system/

# Whole plugin suite
bin/rspec plugins/discourse-npn-revised-critique/spec/

# Lint everything
bin/lint --fix plugins/discourse-npn-revised-critique
```

If you change a `.gjs`/`.scss` file and your **system specs** suddenly
stop seeing your changes (banner missing, wrong classes, old
behaviour), the per-plugin asset bundle is stale. Force a rebuild:

```bash
bundle exec rake assets:precompile:asset_processor
```

Request and unit specs don't need this — only system specs serve the
precompiled plugin JS.

---

## Testing before a Discourse update

CI is wired through
`discourse/.github/.github/workflows/discourse-plugin.yml@v1` and
tests **only** against `core_ref: main` (Discourse "latest" /
tests-passed), because that's what the single production site runs.
Stable isn't a target — see `.github/workflows/discourse-plugin.yml`
for the rationale.

Two quick ways to test against an upcoming Discourse release **before**
it lands:

1. **Locally**: check out the upcoming release branch (e.g.
   `release/2026.7`) inside your local Discourse and run the plugin's
   full suite:

   ```bash
   cd /path/to/discourse
   git fetch && git checkout release/2026.7
   bundle install
   pnpm --filter discourse install
   bin/rspec plugins/discourse-npn-revised-critique/spec/
   ```

2. **In CI**: trigger the workflow against the upcoming branch by
   editing `.github/workflows/discourse-plugin.yml` temporarily:

   ```yaml
   jobs:
     ci:
       uses: discourse/.github/.github/workflows/discourse-plugin.yml@v1
       with:
         core_ref: release/2026.7
   ```

   Open a draft PR with that change, watch it run, revert before
   merging.

When Discourse cuts a `beta` release that the production site is about
to pick up, run the suite against that ref using the same edit pattern
above (`core_ref: beta`) before the rebuild.

---

## Fragile integration points

Places the plugin reaches into Discourse internals. If any of these
changes upstream, the plugin will break. Watch for them in Discourse
changelogs / `git log -- frontend/discourse/app/lib/`.

| Surface | What we use | Where | Failure mode |
| --- | --- | --- | --- |
| `topic-above-posts` plugin outlet | The banner is rendered here via `api.renderInOutlet` | `assets/javascripts/discourse/api-initializers/register-revised-image-button.gjs` | Outlet rename/removal → banner stops appearing entirely. System specs would catch this. Mitigation: switch to `topic-above-post-stream` or `api.renderBeforeWrapperOutlet`. |
| `UppyImageUploader` component | Single-image modal | `assets/javascripts/discourse/components/modal/revised-image-modal.gjs` | `@onUploadDone` payload shape drift (`.id` / `.url` / `.short_url`). Symptom: TypeError on submit or `upload_id: null` server-side. |
| `UppyUpload` class | Project editor | `assets/javascripts/discourse/components/modal/project-revision-editor.gjs` | `setup(fileInput)` / `openPicker()` / `uploadDone` config API. Symptom: clicking Add image or Replace does nothing; or upload completes but `routeUpload` isn't called. |
| `<DModal>` / `<DButton>` / `<DModalCancel>` from `discourse/ui-kit/` | Modal frame for both modals | Both modal files | Recent move from `discourse/components/...`; another rename is plausible. Symptom: module-not-found build error at boot. |
| Template helpers in `discourse/truth-helpers` (`eq`, `not`) | Editor template | `modal/project-revision-editor.gjs` | Rename of the package or export. Symptom: build failure. |
| `TopicViewSerializer.prepend` | Exposes `can_*` booleans + history + editor baseline | `lib/extensions/topic_view_serializer_extension.rb` | If TVS migrates to a contract serializer, our prepend stops adding attributes. Symptom: banner never appears even though Eligibility allows. Probe: hit `/t/<slug>/<id>.json` and check the response keys. |
| `PostRevisor#revise!` flag set | Single-image + project flows | `lib/discourse_revised_critique_image/revision_adder.rb`, `project_revision_adder.rb` | Rename of `skip_validations`, `bypass_bump`, `skip_revision`, or `:title` field → silent edit failures. |
| `Guardian#can_edit?(first_post)` | Authorization defence-in-depth | Both controllers | New gates (silenced groups, locked posts) inherited automatically; watch for the banner suddenly disappearing for users who used to see it. |
| `Upload#short_url` + `link_post_uploads` | Image markdown insertion + S3 access control | Both adders | Plugin relies on "fresh upload referenced for the first time in the first post inherits `access_control_post_id`" (`app/models/concerns/has_post_upload_references.rb`). Contract changes can break secure-upload visibility for non-OP viewers. |
| `RateLimiter` API | Both endpoints | Both controllers | `RateLimiter.new(user, key, max, period).performed!`. Constructor signature has shifted before. |
| `FileHelper.is_supported_image?` | Server-side upload type check | `lib/discourse_revised_critique_image/image_upload_validation.rb` | If it switches from filename to MIME type, the check silently passes/fails on the wrong inputs. |
| `DiscourseNpnSubmissions::TopicMetadata::PROJECT_SUBMISSION_DATA_KEY` | Reading the original project payload | `lib/discourse_revised_critique_image/submissions_compat.rb` | Constant rename → fall back to literal string `"npn_project_submission_data"`. If the submissions plugin renames the field at the **data** level too, project detection silently fails. |
| `DiscourseNpnSubmissions::ProjectPostBuilder::PROJECT_BLOCK_BEGIN/END` | Marker strings | `submissions_compat.rb` | Same shape — value rename means the new strings stop matching, project editor returns `project_data_invalid`. |

When upstream changes one of these, prefer adapting our call site over
rebuilding the feature — every line of compatibility shim is a future
bug.

---

## Rollback steps

If a release of the plugin breaks production:

1. **Identify the last good commit/tag**:

   ```bash
   git -C /path/to/plugin tag --sort=-creatordate | head -10
   # or
   git -C /path/to/plugin log --oneline main | head -20
   ```

2. **Pin the working version in `app.yml`** on the live forum:

   ```yaml
   hooks:
     after_code:
       - exec:
           cd: $home/plugins
           cmd:
             - git clone https://github.com/davidkingham/discourse-npn-revised-critique.git
             - cd discourse-npn-revised-critique && git checkout <SHA-or-tag>
   ```

3. **Rebuild**:

   ```bash
   cd /var/discourse && ./launcher rebuild app
   ```

4. **Roll forward**: once the issue is fixed, drop the `git checkout`
   line so the next rebuild pulls `latest` again.

### Rolling back the data

The plugin stores revision history in topic custom fields. Rolling
back the plugin code does **not** remove these. If you also need to
clear the data for a topic:

```ruby
# bin/rails console
topic = Topic.find(TOPIC_ID)

# Single-image keys
%w[
  revised_image_history
  revised_image_upload_id
  revised_image_added_at
  revised_image_added_by_user_id
  revised_image_note
  npn_revision_count
  npn_latest_revision_upload_id
  npn_latest_revision_image_url
  npn_revision_images
  npn_critique_image_version_schema
].each { |k| topic.custom_fields.delete(k) }

# Project revision keys (Phase 3+) — do NOT delete
# npn_project_submission_data; that's owned by the submissions plugin.
%w[
  npn_project_revisions
  npn_project_revisions_schema
].each { |k| topic.custom_fields.delete(k) }

topic.save_custom_fields(true)
```

### Stripping the single-image block from a post

```ruby
post = Topic.find(ID).first_post
post.update!(
  raw: post.raw.sub(
    /<!-- revised-critique-image:begin -->.*?<!-- revised-critique-image:end -->\s*/m,
    "",
  ).sub(/\A## Original Version\s*\n+/, ""),
)
```

### Stripping a project revision block back to original

The project markers themselves stay in place (the submissions plugin
owns them). What changes is the **content** between markers. To revert
the slice back to what the submissions plugin originally wrote, the
cleanest path is to delete the `npn_project_revisions` custom field
(see above) and re-cook the post — but the post-body content won't
auto-restore. You'd need to re-run the submissions plugin's
`ProjectPostBuilder.build(submission)` against the original
`Submission` row and splice the result back in. There's no convenience
helper for this yet; if you find yourself doing it more than once,
extract one.
