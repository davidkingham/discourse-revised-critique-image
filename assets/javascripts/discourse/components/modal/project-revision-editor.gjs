import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import UppyImageUploader from "discourse/components/uppy-image-uploader";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq, not } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import DModalCancel from "discourse/ui-kit/d-modal-cancel";
import { i18n } from "discourse-i18n";

const HARD_IMAGE_LIMIT = 12;

let nextLocalId = 0;
function generateLocalId() {
  nextLocalId += 1;
  return `new-${Date.now()}-${nextLocalId}`;
}

export default class ProjectRevisionEditor extends Component {
  @service router;
  @service siteSettings;

  // The editable card list. Each entry mirrors the shape the backend
  // expects on save: { id, upload_id, short_url, image_url, caption, alt }.
  // image_url is purely for browser display; the server doesn't read it.
  @tracked images = [];
  @tracked note = "";
  @tracked submitting = false;
  @tracked errorMessage = null;

  constructor() {
    super(...arguments);
    this.loadBaseline();
  }

  get topic() {
    return this.args.model.topic;
  }

  get mode() {
    return this.args.model.mode === "replace_latest" ? "replace_latest" : "add";
  }

  get isReplaceMode() {
    return this.mode === "replace_latest";
  }

  get maxImages() {
    const cap = parseInt(
      this.siteSettings.revised_critique_max_project_images,
      10
    );
    if (Number.isNaN(cap) || cap <= 0 || cap > HARD_IMAGE_LIMIT) {
      return HARD_IMAGE_LIMIT;
    }
    return cap;
  }

  get atMaxImages() {
    return this.images.length >= this.maxImages;
  }

  get canSave() {
    return !this.submitting && this.images.length > 0;
  }

  get title() {
    if (this.isReplaceMode) {
      return i18n(
        "discourse_revised_critique_image.project_editor.title_replace_latest"
      );
    }
    const editor = this.topic?.project_revision_editor;
    if (editor && editor.latest) {
      return i18n(
        "discourse_revised_critique_image.project_editor.title_add_another"
      );
    }
    return i18n(
      "discourse_revised_critique_image.project_editor.title_add_first"
    );
  }

  get submitLabel() {
    if (this.submitting) {
      return i18n("discourse_revised_critique_image.project_editor.submitting");
    }
    if (this.isReplaceMode) {
      return i18n(
        "discourse_revised_critique_image.project_editor.submit_replace_latest"
      );
    }
    return i18n("discourse_revised_critique_image.project_editor.submit_add");
  }

  // Pull the baseline images out of the serialized editor payload. For
  // `add` we prefer the latest revision (so "add another" starts from
  // where the user left off); for `replace_latest` we always use the
  // latest. If neither is present we fall back to the original
  // submission so the first project revision starts from the OP image set.
  loadBaseline() {
    const editor = this.topic?.project_revision_editor || {};
    let baseline = null;

    if (this.isReplaceMode) {
      baseline = editor.latest || null;
    } else {
      baseline = editor.latest || editor.original || null;
    }

    if (!baseline) {
      baseline = editor.original || { images: [], note: "" };
    }

    this.images = (baseline.images || []).map((img) => ({
      ...img,
      // The note travels separately; per-image fields are immutable here
      // except via the action methods below.
    }));

    // Pre-populate the note ONLY on replace_latest (editing in place);
    // "add another" gets a fresh note so the user describes THIS round
    // of changes, not the previous round's.
    this.note = this.isReplaceMode ? baseline.note || "" : "";
  }

  isLast(index) {
    return index >= this.images.length - 1;
  }

  positionLabel(index) {
    return i18n("discourse_revised_critique_image.project_editor.image_label", {
      number: index + 1,
    });
  }

  @action
  updateNote(event) {
    this.note = event.target.value;
  }

  @action
  updateCaption(index, event) {
    const next = [...this.images];
    next[index] = { ...next[index], caption: event.target.value };
    this.images = next;
  }

  @action
  moveLeft(index) {
    if (index <= 0) {
      return;
    }
    const next = [...this.images];
    [next[index - 1], next[index]] = [next[index], next[index - 1]];
    this.images = next;
  }

  @action
  moveRight(index) {
    if (this.isLast(index)) {
      return;
    }
    const next = [...this.images];
    [next[index], next[index + 1]] = [next[index + 1], next[index]];
    this.images = next;
  }

  @action
  removeImage(index) {
    if (this.images.length <= 1) {
      this.errorMessage = i18n(
        "discourse_revised_critique_image.project_editor.error_min_one_image"
      );
      return;
    }
    const next = [...this.images];
    next.splice(index, 1);
    this.images = next;
  }

  @action
  onReplaceUploaded(cardId, upload) {
    const next = this.images.map((img) =>
      img.id === cardId
        ? {
            ...img,
            upload_id: upload.id,
            short_url: upload.short_url,
            image_url: upload.url,
          }
        : img
    );
    this.images = next;
  }

  @action
  onAddUploaded(upload) {
    if (this.atMaxImages) {
      this.errorMessage = i18n(
        "discourse_revised_critique_image.project_editor.error_too_many_images",
        { max: this.maxImages }
      );
      return;
    }
    this.images = [
      ...this.images,
      {
        id: generateLocalId(),
        upload_id: upload.id,
        short_url: upload.short_url,
        image_url: upload.url,
        caption: "",
        alt: `Image ${this.images.length + 1}`,
      },
    ];
  }

  // The Uppy uploader instance for "Add" doesn't auto-clear after
  // upload completes, but we don't surface its preview either — the
  // newly-added image already shows up as a card. We do clear the
  // generic error message on any successful action.
  clearError() {
    this.errorMessage = null;
  }

  @action
  async save() {
    if (!this.canSave) {
      return;
    }
    this.submitting = true;
    this.errorMessage = null;

    try {
      await ajax(
        `/revised-critique-image/topics/${this.topic.id}/project-revisions`,
        {
          type: "POST",
          data: {
            mode: this.mode,
            note: this.note.trim(),
            images: this.images.map((img) => ({
              id: img.id,
              upload_id: img.upload_id,
              caption: img.caption || "",
            })),
          },
        }
      );

      this.args.closeModal();
      this.router.refresh();
    } catch (e) {
      // popupAjaxError surfaces the server's `errors` array via the
      // global toast UI; we also pin the message into the modal so the
      // user can see the failure without dismissing the modal first.
      const body = e?.jqXHR?.responseJSON || {};
      const messages = body.errors || [];
      this.errorMessage =
        messages[0] ||
        i18n("discourse_revised_critique_image.project_editor.error_generic");
      popupAjaxError(e);
    } finally {
      this.submitting = false;
    }
  }

  <template>
    <DModal
      class="project-revision-editor"
      @title={{this.title}}
      @closeModal={{@closeModal}}
    >
      <:body>
        <p class="project-revision-editor__description">
          {{i18n "discourse_revised_critique_image.project_editor.description"}}
        </p>

        <div class="project-revision-editor__note">
          <label
            for="project-revision-note"
            class="project-revision-editor__note-label"
          >
            {{i18n
              "discourse_revised_critique_image.project_editor.note_label"
            }}
          </label>
          <textarea
            id="project-revision-note"
            class="project-revision-editor__note-input"
            rows="3"
            placeholder={{i18n
              "discourse_revised_critique_image.project_editor.note_placeholder"
            }}
            value={{this.note}}
            {{on "input" this.updateNote}}
          ></textarea>
        </div>

        <ol class="project-revision-editor__cards" aria-live="polite">
          {{#each this.images key="id" as |img idx|}}
            <li
              class="project-revision-editor__card"
              data-card-id={{img.id}}
              data-position={{idx}}
            >
              <div class="project-revision-editor__card-thumb">
                <UppyImageUploader
                  @id={{concat "prj-card-" img.id}}
                  @type="revised_critique_image"
                  @imageUrl={{img.image_url}}
                  @onUploadDone={{fn this.onReplaceUploaded img.id}}
                />
              </div>
              <div class="project-revision-editor__card-meta">
                <span class="project-revision-editor__card-position">
                  {{this.positionLabel idx}}
                </span>
                <label class="project-revision-editor__card-caption-label">
                  {{i18n
                    "discourse_revised_critique_image.project_editor.caption_label"
                  }}
                  <input
                    type="text"
                    class="project-revision-editor__card-caption-input"
                    value={{img.caption}}
                    {{on "input" (fn this.updateCaption idx)}}
                  />
                </label>
                <div class="project-revision-editor__card-actions">
                  <DButton
                    class="project-revision-editor__card-move-left"
                    @action={{fn this.moveLeft idx}}
                    @disabled={{eq idx 0}}
                    @label="discourse_revised_critique_image.project_editor.move_left"
                  />
                  <DButton
                    class="project-revision-editor__card-move-right"
                    @action={{fn this.moveRight idx}}
                    @disabled={{this.isLast idx}}
                    @label="discourse_revised_critique_image.project_editor.move_right"
                  />
                  <DButton
                    class="project-revision-editor__card-remove btn-danger"
                    @action={{fn this.removeImage idx}}
                    @label="discourse_revised_critique_image.project_editor.remove"
                  />
                </div>
              </div>
            </li>
          {{/each}}
        </ol>

        {{#unless this.atMaxImages}}
          <div class="project-revision-editor__add">
            <h4 class="project-revision-editor__add-heading">
              {{i18n
                "discourse_revised_critique_image.project_editor.add_image_heading"
              }}
            </h4>
            <UppyImageUploader
              @id="prj-editor-add"
              @type="revised_critique_image"
              @onUploadDone={{this.onAddUploaded}}
            />
          </div>
        {{/unless}}

        {{#if this.errorMessage}}
          <p class="project-revision-editor__error" role="alert">
            {{this.errorMessage}}
          </p>
        {{/if}}
      </:body>

      <:footer>
        <DButton
          class="btn-primary project-revision-editor__submit"
          @action={{this.save}}
          @disabled={{not this.canSave}}
          @translatedLabel={{this.submitLabel}}
        />
        <DModalCancel @close={{@closeModal}} />
      </:footer>
    </DModal>
  </template>
}
