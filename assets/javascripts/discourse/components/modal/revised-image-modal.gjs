import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import UppyImageUploader from "discourse/components/uppy-image-uploader";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import DModalCancel from "discourse/ui-kit/d-modal-cancel";
import { i18n } from "discourse-i18n";

export default class RevisedImageModal extends Component {
  @service router;
  @service siteSettings;

  @tracked uploadedImageUrl;
  @tracked uploadedUploadId;
  @tracked note = "";
  @tracked submitting = false;

  get topic() {
    return this.args.model.topic;
  }

  get maxNoteLength() {
    return parseInt(this.siteSettings.revised_critique_note_max_length, 10) || 500;
  }

  get noteTooLong() {
    return this.note.length > this.maxNoteLength;
  }

  get remainingChars() {
    return this.maxNoteLength - this.note.length;
  }

  get submitDisabled() {
    return this.submitting || !this.uploadedUploadId || this.noteTooLong;
  }

  @action
  onUploadDone(upload) {
    this.uploadedImageUrl = upload.url;
    this.uploadedUploadId = upload.id;
  }

  @action
  onUploadDeleted() {
    this.uploadedImageUrl = null;
    this.uploadedUploadId = null;
  }

  @action
  onNoteInput(event) {
    this.note = event.target.value;
  }

  @action
  async submit() {
    if (this.submitDisabled) {
      return;
    }

    this.submitting = true;
    try {
      await ajax(`/revised-critique-image/topics/${this.topic.id}/revisions`, {
        type: "POST",
        data: { upload_id: this.uploadedUploadId, note: this.note.trim() },
      });

      this.args.closeModal();
      this.router.refresh();
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.submitting = false;
    }
  }

  <template>
    <DModal
      class="revised-image-modal"
      @title={{i18n "discourse_revised_critique_image.modal.title"}}
      @closeModal={{@closeModal}}
    >
      <:body>
        <p class="revised-image-modal__description">
          {{i18n "discourse_revised_critique_image.modal.description"}}
        </p>

        <UppyImageUploader
          @id="revised-image-uploader"
          @type="revised_critique_image"
          @imageUrl={{this.uploadedImageUrl}}
          @onUploadDone={{this.onUploadDone}}
          @onUploadDeleted={{this.onUploadDeleted}}
        />

        <div class="revised-image-modal__note">
          <label for="revised-image-note" class="revised-image-modal__note-label">
            {{i18n "discourse_revised_critique_image.modal.note_label"}}
          </label>
          <p class="revised-image-modal__note-helper">
            {{i18n "discourse_revised_critique_image.modal.note_helper"}}
          </p>
          <textarea
            id="revised-image-note"
            class="revised-image-modal__note-input"
            rows="3"
            maxlength={{this.maxNoteLength}}
            placeholder={{i18n
              "discourse_revised_critique_image.modal.note_placeholder"
            }}
            value={{this.note}}
            {{on "input" this.onNoteInput}}
          ></textarea>
          <p
            class="revised-image-modal__note-counter
              {{if this.noteTooLong 'revised-image-modal__note-counter--over'}}"
          >
            {{#if this.noteTooLong}}
              {{i18n
                "discourse_revised_critique_image.errors.note_too_long"
                max=this.maxNoteLength
              }}
            {{else}}
              {{i18n
                "discourse_revised_critique_image.modal.note_counter"
                remaining=this.remainingChars
              }}
            {{/if}}
          </p>
        </div>
      </:body>

      <:footer>
        <DButton
          class="btn-primary revised-image-modal__submit"
          @action={{this.submit}}
          @disabled={{this.submitDisabled}}
          @label={{if
            this.submitting
            "discourse_revised_critique_image.modal.submitting"
            "discourse_revised_critique_image.modal.submit"
          }}
        />
        <DModalCancel @close={{@closeModal}} />
      </:footer>
    </DModal>
  </template>
}
