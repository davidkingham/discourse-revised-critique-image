# discourse-revised-critique-image

Lets the original poster of an image critique topic add a "Revised Version"
of their image after receiving feedback from the community. The revised image
is inserted as a markdown block at the top of the first post.

## Site settings

| Setting | Default | Description |
| --- | --- | --- |
| `revised_critique_enabled` | `true` | Master switch. |
| `revised_critique_category_id` | `-1` | Category the topic must belong to. |
| `revised_critique_button_label` | `"Add Revised Image"` | Topic-level button label. |
| `revised_critique_heading` | `"Revised Version"` | Heading for the revision block. |
| `revised_critique_require_reply_from_other_user` | `true` | Require a reply from another user. |
| `revised_critique_allow_replace` | `false` | Allow replacing an existing revision. |
| `revised_critique_add_notice_reply` | `false` | Post a small notice reply after adding. |

## Behaviour

When the conditions are met the original poster sees an "Add Revised Image"
button on their topic. Clicking it opens a modal where they can upload an
image. On submit the plugin edits the raw markdown of the first post to add
a "Revised Version" block above the original content and stores three topic
custom fields:

- `revised_image_upload_id`
- `revised_image_added_at`
- `revised_image_added_by_user_id`
