# Maintenance

Notes for keeping the plugin healthy as Discourse evolves.

## Running specs locally

The plugin lives at `plugins/discourse-npn-revised-critique/` inside a
local Discourse checkout. From the Discourse repo root:

```bash
# Request specs (controller + service + security guards)
bin/rspec plugins/discourse-npn-revised-critique/spec/requests/

# System specs (banner visibility + modal flow, needs Playwright)
bin/rspec plugins/discourse-npn-revised-critique/spec/system/

# Whole plugin suite
bin/rspec plugins/discourse-npn-revised-critique/spec/

# Lint everything
bin/lint --fix plugins/discourse-npn-revised-critique
```

If you change a `.gjs`/`.scss` file and your **system specs** suddenly stop
seeing your changes (banner missing, wrong classes, old behaviour), the
problem is almost always that Discourse's per-plugin asset bundle has been
cached. Force a rebuild:

```bash
bundle exec rake assets:precompile:asset_processor
```

Request specs don't need this — only system specs serve the precompiled
plugin JS.

## Testing before a Discourse update

CI is wired through `discourse/.github/.github/workflows/discourse-plugin.yml@v1`
and tests against `core_ref: "latest"` by default. Two quick ways to test
against an upcoming Discourse release **before** it lands:

1. **Locally**: check out the upcoming release branch (e.g. `release/2026.4`)
   inside your local Discourse and run the plugin's full suite:

   ```bash
   cd /path/to/discourse
   git fetch && git checkout release/2026.4
   bundle install
   pnpm --filter discourse install
   bin/rspec plugins/discourse-npn-revised-critique/spec/
   ```

2. **In CI**: trigger the workflow against the upcoming branch by editing
   `.github/workflows/discourse-plugin.yml` temporarily:

   ```yaml
   jobs:
     ci:
       uses: discourse/.github/.github/workflows/discourse-plugin.yml@v1
       with:
         core_ref: release/2026.4
   ```

   Open a draft PR with that change, watch it run, revert before merging.

When Discourse cuts a `stable` or `beta` release, run the suite against
those refs too if you support multiple release channels.

## Fragile integration points

These are places the plugin reaches into Discourse internals. If any of
them changes upstream, the plugin will break. Watch for these in
Discourse changelogs / `git log -- frontend/discourse/app/lib/`.

| Surface | What we use | Where | Failure mode |
| --- | --- | --- | --- |
| `topic-above-posts` plugin outlet | The banner is rendered here via `api.renderInOutlet` | `assets/javascripts/discourse/api-initializers/register-revised-image-button.gjs:5` | If the outlet is renamed or removed, the banner stops appearing entirely. Symptom: system specs fail to find `.revised-image-banner`. Mitigation: switch to a sibling outlet (`topic-above-post-stream`) or `api.renderBeforeWrapperOutlet`. |
| `UppyImageUploader` component | Modal uses it for upload UX | `assets/javascripts/discourse/components/modal/revised-image-modal.gjs` (import + tag) | Discourse occasionally refactors uploader internals (`@onUploadDone` shape, `@type`). Symptom: TypeError in browser when clicking the button, or `upload_id` arriving null on submit. |
| `<DModal>` + `<DModalCancel>` from `discourse/ui-kit/...` | Modal frame | Same modal file | The `ui-kit` paths replaced older `components/d-modal` paths recently; another rename is plausible. Symptom: module-not-found build error at boot. Fix: follow the deprecation note (Discourse logs the new path before removal). |
| `TopicViewSerializer` prepend | Exposes `can_*` booleans + history fields | `lib/extensions/topic_view_serializer_extension.rb` | If TVS attribute API changes (e.g. moves to a contract serializer), our prepend either does nothing or raises. Symptom: banner never appears even though Eligibility allows it. Probe: hit `/t/<slug>/<id>.json` and check the response keys. |
| `PostRevisor.revise!` with `skip_validations: true` | All raw + title rewrites | `lib/discourse_revised_critique_image/revision_adder.rb` | The `skip_validations` flag, `bypass_bump`, and `:title` field in `fields:` all need to keep existing for our flow. If the flag is renamed, edits will fail with min-body-length errors. |
| `Guardian#can_edit?(first_post)` | Authorization defence-in-depth in the controller | `app/controllers/.../revisions_controller.rb` | The `can_edit_post?` logic occasionally adds new gates (silenced groups, locked posts). New gates should be respected automatically since we delegate, but watch the spec output. |
| `Upload#short_url` + `link_post_uploads` | Image markdown insertion + S3 access control | `lib/discourse_revised_critique_image/revision_adder.rb` | The plugin relies on the rule "fresh uploads get their `access_control_post_id` set on the first referencing post" (`app/models/concerns/has_post_upload_references.rb`). If Discourse changes that contract, secure-upload behaviour may differ. |
| `RateLimiter` API | Per-user limit on the create endpoint | `app/controllers/.../revisions_controller.rb` | `RateLimiter.new(user, key, max, period).performed!` is stable but watch for the constructor signature. |
| `FileHelper.is_supported_image?` | Server-side upload type check | Same controller | If this method moves or changes the input shape (e.g. accepts MIME type instead of filename), the check silently passes/fails. |

When upstream changes one of these, prefer adapting our call site over
rebuilding the feature — every line of compatibility shim is a future
bug.

## Rollback steps

If a release of the plugin breaks production:

1. **Identify the last good tag**:

   ```bash
   git -C /path/to/plugin tag --sort=-creatordate | head -10
   ```

2. **Pin the working version in `app.yml`** on the live forum:

   ```yaml
   hooks:
     after_code:
       - exec:
           cd: $home/plugins
           cmd:
             - git clone https://github.com/davidkingham/discourse-npn-revised-critique.git
             - cd discourse-npn-revised-critique && git checkout v2.0.0
   ```

3. **Rebuild**:

   ```bash
   cd /var/discourse && ./launcher rebuild app
   ```

4. **Roll forward**: once the issue is fixed, drop the `git checkout`
   line so the next rebuild pulls `latest` again.

### Rolling back the data

The plugin stores revision history in topic custom fields. Rolling back
the plugin code does **not** remove these. If you also need to clear the
data for a topic:

```ruby
# bin/rails console
topic = Topic.find(TOPIC_ID)
%w[
  revised_image_history
  revised_image_upload_id
  revised_image_added_at
  revised_image_added_by_user_id
  revised_image_note
].each { |k| topic.custom_fields.delete(k) }
topic.save_custom_fields(true)
```

The revision block in the first post raw is bracketed by HTML comment
markers (`<!-- revised-critique-image:begin -->` / `:end -->`) so it's
easy to strip in a console or migration if you ever need to:

```ruby
post = Topic.find(ID).first_post
post.update!(
  raw: post.raw.sub(
    /<!-- revised-critique-image:begin -->.*?<!-- revised-critique-image:end -->\s*/m,
    "",
  ).sub(/\A## Original Version\s*\n+/, ""),
)
```

That returns the post to its pre-plugin state. Re-cooking happens on the
next save automatically.
