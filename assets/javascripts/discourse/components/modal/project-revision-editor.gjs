import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import UppyUpload from "discourse/lib/uppy/uppy-upload";
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

// Defensively rebuild an image entry so each card has a unique, non-blank
// id even if the persisted data was corrupted upstream. Duplicate ids on
// cards would also break Glimmer's @each key="id" reactivity.
function normalizeBaselineImages(images) {
  const seenIds = new Set();
  return (images || []).map((img) => {
    let id = img.id;
    if (!id || typeof id !== "string" || seenIds.has(id)) {
      id = generateLocalId();
    }
    seenIds.add(id);
    return { ...img, id };
  });
}

export default class ProjectRevisionEditor extends Component {
  @service router;
  @service siteSettings;

  @tracked images = [];
  @tracked note = "";
  @tracked submitting = false;
  @tracked errorMessage = null;

  // Tracks where the next successful upload should go:
  //   { kind: "add" }                 → push a new card at the end
  //   { kind: "replace", id: <cardId> } → swap the named card's upload
  // Reset to null after each upload is consumed.
  @tracked nextUploadTarget = null;

  // One shared file input + UppyUpload instance for both "Add Image"
  // and per-card "Replace Image". Multiple per-card UppyUploaders made
  // the modal noisy AND collided around UppyUpload's id-keyed appEvents
  // bus; routing every upload through a single instance is simpler and
  // matches how Discourse's composer handles inline upload buttons.
  uppyUpload = new UppyUpload(getOwner(this), {
    id: "project-revision-editor",
    type: "revised_critique_image",
    validateUploadedFilesOptions: { imagesOnly: true },
    uploadDone: (upload) => this.routeUpload(upload),
  });

  constructor() {
    super(...arguments);
    this.loadBaseline();
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.uppyUpload?.teardown?.();
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

  get atMinImages() {
    return this.images.length <= 1;
  }

  get canSave() {
    return !this.submitting && this.images.length > 0;
  }

  // Pre-computed indices for template comparisons. Glimmer can only call
  // bare component methods from templates when they're explicitly bound
  // (e.g. with `@action`); exposing these as getters lets the template
  // use plain `eq` / comparison helpers, which is the conventional
  // Discourse pattern.
  get lastIndex() {
    return this.images.length - 1;
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

  loadBaseline() {
    const editor = this.topic?.project_revision_editor || {};
    let baseline;
    if (this.isReplaceMode) {
      baseline = editor.latest || editor.original || { images: [], note: "" };
    } else {
      baseline = editor.latest || editor.original || { images: [], note: "" };
    }

    this.images = normalizeBaselineImages(baseline.images);
    this.note = this.isReplaceMode ? baseline.note || "" : "";

    if (this.images.length === 0) {
      // No baseline images — the editor still opens but a save will
      // be blocked client-side by the atMinImages guard. Surface a
      // hint so the OP knows what's missing.
      this.errorMessage = i18n(
        "discourse_revised_critique_image.project_editor.error_no_baseline"
      );
    }
  }

  // positionLabel doesn't reference `this`, so the template's
  // `{{this.positionLabel idx}}` happens to work even unbound; but mark
  // it @action anyway to make the convention consistent with the rest
  // of the file and to survive any future refactor that adds a `this.`
  // reference inside.
  @action
  positionLabel(index) {
    return i18n("discourse_revised_critique_image.project_editor.image_label", {
      number: index + 1,
    });
  }

  @action
  registerFileInput(element) {
    this.uppyUpload.setup(element);
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
    this.clearError();
  }

  @action
  moveRight(index) {
    if (index >= this.lastIndex) {
      return;
    }
    const next = [...this.images];
    [next[index], next[index + 1]] = [next[index + 1], next[index]];
    this.images = next;
    this.clearError();
  }

  @action
  removeImage(index) {
    if (this.atMinImages) {
      this.errorMessage = i18n(
        "discourse_revised_critique_image.project_editor.error_min_one_image"
      );
      return;
    }
    const next = [...this.images];
    next.splice(index, 1);
    this.images = next;
    this.clearError();
  }

  @action
  triggerAdd() {
    if (this.atMaxImages) {
      this.errorMessage = i18n(
        "discourse_revised_critique_image.project_editor.error_too_many_images",
        { max: this.maxImages }
      );
      return;
    }
    this.nextUploadTarget = { kind: "add" };
    this.uppyUpload.openPicker();
  }

  @action
  triggerReplace(cardId) {
    this.nextUploadTarget = { kind: "replace", id: cardId };
    this.uppyUpload.openPicker();
  }

  // Single sink for every completed upload from the shared UppyUpload.
  routeUpload(upload) {
    const target = this.nextUploadTarget || { kind: "add" };
    this.nextUploadTarget = null;

    if (target.kind === "replace") {
      this.images = this.images.map((img) =>
        img.id === target.id
          ? {
              ...img,
              upload_id: upload.id,
              short_url: upload.short_url,
              image_url: upload.url,
            }
          : img
      );
    } else {
      if (this.atMaxImages) {
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
    this.clearError();
  }

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

      // Close BEFORE refreshing so the modal is fully unmounted by
      // the time the route re-renders the topic.
      this.args.closeModal();
      this.router.refresh();
    } catch (e) {
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
      class="project-revision-editor -large"
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
          {{#each this.images key="id" as |card idx|}}
            <li
              class="project-revision-editor__card"
              data-card-id={{card.id}}
              data-position={{idx}}
            >
              <div class="project-revision-editor__card-thumb">
                {{#if card.image_url}}
                  <img
                    class="project-revision-editor__card-image"
                    src={{card.image_url}}
                    alt={{card.alt}}
                    loading="lazy"
                  />
                {{else}}
                  <div class="project-revision-editor__card-placeholder">
                    {{i18n
                      "discourse_revised_critique_image.project_editor.image_pending"
                    }}
                  </div>
                {{/if}}
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
                    id={{concat "prj-caption-" card.id}}
                    type="text"
                    class="project-revision-editor__card-caption-input"
                    value={{card.caption}}
                    {{on "input" (fn this.updateCaption idx)}}
                  />
                </label>
                <div class="project-revision-editor__card-actions">
                  <DButton
                    class="project-revision-editor__card-move-left"
                    @action={{fn this.moveLeft idx}}
                    @disabled={{eq idx 0}}
                    @icon="arrow-left"
                    @label="discourse_revised_critique_image.project_editor.move_left"
                  />
                  <DButton
                    class="project-revision-editor__card-move-right"
                    @action={{fn this.moveRight idx}}
                    @disabled={{eq idx this.lastIndex}}
                    @icon="arrow-right"
                    @label="discourse_revised_critique_image.project_editor.move_right"
                  />
                  <DButton
                    class="project-revision-editor__card-replace"
                    @action={{fn this.triggerReplace card.id}}
                    @icon="arrows-rotate"
                    @label="discourse_revised_critique_image.project_editor.replace"
                  />
                  <DButton
                    class="project-revision-editor__card-remove btn-danger"
                    @action={{fn this.removeImage idx}}
                    @disabled={{this.atMinImages}}
                    @icon="trash-can"
                    @label="discourse_revised_critique_image.project_editor.remove"
                  />
                </div>
              </div>
            </li>
          {{/each}}
        </ol>

        <div class="project-revision-editor__add">
          <DButton
            class="btn-default project-revision-editor__add-button"
            @action={{this.triggerAdd}}
            @disabled={{this.atMaxImages}}
            @icon="plus"
            @label="discourse_revised_critique_image.project_editor.add_image"
          />
          <p class="project-revision-editor__add-helper">
            {{i18n
              "discourse_revised_critique_image.project_editor.add_image_helper"
              max=this.maxImages
            }}
          </p>
        </div>

        {{#if this.errorMessage}}
          <p class="project-revision-editor__error" role="alert">
            {{this.errorMessage}}
          </p>
        {{/if}}

        <input
          type="file"
          class="project-revision-editor__file-input"
          accept="image/*"
          aria-hidden="true"
          tabindex="-1"
          {{didInsert this.registerFileInput}}
        />
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
