# discourse-npn-revised-critique

A [Discourse](https://discourse.org) plugin that lets the original poster of an
image-critique topic share a **revised version** of their image after they've
received feedback. The revised image is inserted at the top of the first post,
the topic title gets a configurable marker, and the OP can optionally leave a
short note about what they changed.

Designed for photography, illustration, and design critique communities where
the "before / after" of feedback is part of the value of the discussion.

![Example: revised version block](https://user-images.githubusercontent.com/placeholder/revised-version-example.png)

## Features

- **Topic-level banner** above the posts that only appears when the current
  user is the OP, the topic is in the configured critique category, has at
  least one reply from another user, and the OP can still edit their first
  post.
- **Upload modal** built on Discourse's standard `<DModal>` + `UppyImageUploader`
  — same upload pipeline (and S3/CDN handling) as the regular composer.
- **Optional "What did you change?" note** with client- and server-side
  length limits.
- **Configurable title marker** (default `(+revised)`) appended to the topic
  title after a successful revision. Best-effort: skipped silently if it
  would exceed `max_topic_title_length`.
- **Replacement support** for editing or re-revising. Optional, off by default.
- **Optional notice reply** posted by the system user or any admin you choose,
  so subscribers get notified.
- **Rate-limited** server-side (6 per hour per user, staff bypass) so the
  revision flow can't be abused.

## How it works

Successful revisions insert a markdown block at the top of the first post:

```markdown
<!-- revised-critique-image:begin -->
## Revised Version

![Revised version|800x600](upload://abc123.jpg)

**What changed:** Pulled down the highlights and warmed the white balance.

*Added after receiving feedback from the community.*

---
<!-- revised-critique-image:end -->

## Original Version

[the original post content stays here, untouched]
```

The HTML-comment markers around the revision block let the plugin cleanly
replace an existing revision (when replacement is enabled) without touching
the original content.

The plugin also stores four topic custom fields:

| Custom field | Type | Use |
| --- | --- | --- |
| `revised_image_upload_id` | integer | The `Upload#id` of the revised image |
| `revised_image_added_at` | iso8601 string | When the revision was added |
| `revised_image_added_by_user_id` | integer | Who added it (always the OP) |
| `revised_image_note` | string | Optional "what changed" note |

## Installation

Add the repo to your `app.yml` under the `hooks → after_code → cmd` block:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/davidkingham/discourse-npn-revised-critique.git
```

Then rebuild your container:

```bash
cd /var/discourse
./launcher rebuild app
```

After the rebuild, the plugin's site settings appear under **Admin → Settings →
Plugins → Discourse Revised Critique Image**.

## Configuration

| Setting | Default | Description |
| --- | --- | --- |
| `revised_critique_enabled` | `true` | Master switch. |
| `revised_critique_category_id` | `0` | The category topics must belong to. **Required** — set this to the ID of your critique category, otherwise the plugin is effectively off. |
| `revised_critique_button_label` | `"Share Revised Version"` | The text on the topic-level button. |
| `revised_critique_title_marker` | `"(+revised)"` | The string appended to the topic title after a successful revision. Set blank to disable. |
| `revised_critique_heading` | `"Revised Version"` | The heading inserted at the top of the revision block. |
| `revised_critique_note_max_length` | `500` | Maximum length of the optional "what changed" note (client- and server-enforced). |
| `revised_critique_require_reply_from_other_user` | `true` | Require at least one reply from a non-OP before the button appears. |
| `revised_critique_allow_replace` | `false` | Allow the OP to replace an existing revision. |
| `revised_critique_add_notice_reply` | `false` | Post a small notice reply when a revision is added. |
| `revised_critique_notice_reply_username` | `"system"` | Username that posts the notice reply. Set to any admin username to attribute it to them. |

### Required permissions

The OP must:

- Be the topic author.
- Be permitted to edit posts (member of `edit_post_allowed_groups`, default TL0+).
- Have a topic that is **not** closed, archived, or deleted.
- Still be within the post-edit time limit (or be staff).
- Not be suspended.

All of these are enforced server-side; the frontend just hides the button when
the conditions aren't met.

## Security model

- **CSRF**: inherited from `ApplicationController` (`protect_from_forgery`). No
  bypass.
- **Authorization**: every rule is enforced in the controller via the
  `Eligibility` class, and re-checked via `Guardian#can_edit?` immediately
  before invoking `PostRevisor.revise!`.
- **Rate limit**: 6 revisions per user per hour (staff bypass). Returns
  HTTP 429 with a structured error key on excess.
- **Upload safety**: matches Discourse's normal composer model. The plugin
  inserts only `upload://` short URLs, never local paths or hardcoded CDN
  URLs. Access to the rendered image is gated by Discourse's standard
  `Guardian#can_see_upload?` at serve time — the same gate used by the
  composer. Inserting a `upload_id` you don't have access to doesn't grant
  any access; viewers without permission see a broken image.
- **No `skip_before_action`** anywhere in the plugin.
- **`PostRevisor.revise!` with `skip_validations: true`** is used so an OP
  with a short post body (e.g. just an image) can still revise. Authorization
  is enforced upstream by `Eligibility` and `Guardian#can_edit?` — that
  flag only bypasses ActiveRecord *validations*, not authorization.

## Development

Tests run against a local Discourse dev environment:

```bash
# Request specs (controller + service + security guards)
bin/rspec plugins/discourse-npn-revised-critique/spec/requests/

# System specs (banner visibility, modal flow)
bin/rspec plugins/discourse-npn-revised-critique/spec/system/

# Lint
bin/lint --fix plugins/discourse-npn-revised-critique
```

The plugin uses Discourse's standard `topic-above-posts` plugin outlet for
the banner — no DOM manipulation, no jQuery.

## License

[MIT](LICENSE)
