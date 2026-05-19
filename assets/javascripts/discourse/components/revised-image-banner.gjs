import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import RevisedImageModal from "./modal/revised-image-modal";

export default class RevisedImageBanner extends Component {
  @service modal;
  @service siteSettings;

  get topic() {
    return this.args.outletArgs?.model;
  }

  get show() {
    return Boolean(
      this.siteSettings.revised_critique_enabled &&
        this.topic?.can_add_revised_critique_image
    );
  }

  get buttonLabel() {
    return (
      this.siteSettings.revised_critique_button_label ||
      i18n("discourse_revised_critique_image.button_label")
    );
  }

  @action
  openModal() {
    this.modal.show(RevisedImageModal, { model: { topic: this.topic } });
  }

  <template>
    {{#if this.show}}
      <div class="revised-image-banner">
        <p class="revised-image-banner__message">
          {{i18n "discourse_revised_critique_image.eligible_message"}}
        </p>
        <DButton
          class="btn-primary revised-image-banner__button"
          @action={{this.openModal}}
          @icon="wand-magic-sparkles"
          @translatedLabel={{this.buttonLabel}}
        />
      </div>
    {{/if}}
  </template>
}
