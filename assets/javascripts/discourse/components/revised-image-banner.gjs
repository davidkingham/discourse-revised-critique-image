import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import ProjectRevisionEditor from "./modal/project-revision-editor";
import RevisedImageModal from "./modal/revised-image-modal";

export default class RevisedImageBanner extends Component {
  @service modal;
  @service siteSettings;
  @service currentUser;

  get topic() {
    return this.args.outletArgs?.model;
  }

  get pluginEnabled() {
    return Boolean(this.siteSettings.revised_critique_enabled);
  }

  // ---- single-image flow ------------------------------------------------

  get canAdd() {
    return Boolean(this.topic?.can_add_revised_critique_image);
  }

  get canReplaceLatest() {
    return Boolean(this.topic?.can_replace_latest_revised_critique_image);
  }

  get show() {
    return this.pluginEnabled && (this.canAdd || this.canReplaceLatest);
  }

  get hasRevisions() {
    return (this.topic?.revised_critique_image_revision_count || 0) > 0;
  }

  // Three states: before first revision, between, at max.
  get state() {
    if (!this.hasRevisions) {
      return "first";
    }
    return this.canAdd ? "mixed" : "atMax";
  }

  get message() {
    switch (this.state) {
      case "first":
        return i18n("discourse_revised_critique_image.eligible_message");
      case "mixed":
        return i18n(
          "discourse_revised_critique_image.can_replace_or_add_message"
        );
      case "atMax":
        return i18n("discourse_revised_critique_image.at_max_message");
    }
    return "";
  }

  get primaryButtonLabel() {
    if (this.state === "first") {
      return (
        this.siteSettings.revised_critique_button_label ||
        i18n("discourse_revised_critique_image.button_label")
      );
    }
    return i18n("discourse_revised_critique_image.replace_latest_label");
  }

  get primaryButtonMode() {
    return this.state === "first" ? "add" : "replace_latest";
  }

  get primaryButtonIcon() {
    return this.state === "first" ? "image" : "arrows-rotate";
  }

  get showAddAnotherButton() {
    return this.state === "mixed";
  }

  get stateClass() {
    const suffix = this.state === "atMax" ? "at-max" : this.state;
    return `revised-image-banner--${suffix}`;
  }

  @action
  openPrimary() {
    this.openModal(this.primaryButtonMode);
  }

  @action
  openAddAnother() {
    this.openModal("add");
  }

  openModal(mode) {
    this.modal.show(RevisedImageModal, {
      model: { topic: this.topic, mode },
    });
  }

  // ---- project flow -----------------------------------------------------

  get isProjectTopic() {
    return this.topic?.revised_critique_revision_type === "project";
  }

  get isTopicOwner() {
    return (
      this.currentUser?.id &&
      this.topic?.user_id &&
      this.currentUser.id === this.topic.user_id
    );
  }

  get isStaff() {
    return Boolean(this.currentUser?.staff);
  }

  get canAddProject() {
    return Boolean(this.topic?.can_add_project_revision);
  }

  get canReplaceLatestProject() {
    return Boolean(this.topic?.can_replace_latest_project_revision);
  }

  get hasProjectRevisions() {
    return (this.topic?.project_revision_count || 0) > 0;
  }

  // Mirrors the single-image state ladder so the markup branches stay
  // symmetric. "first" → only Revise Project; "mixed" → both buttons;
  // "atMax" → only Replace Latest.
  get projectState() {
    if (!this.hasProjectRevisions) {
      return "first";
    }
    return this.canAddProject ? "mixed" : "atMax";
  }

  get showProjectActions() {
    return (
      this.pluginEnabled &&
      this.isProjectTopic &&
      (this.canAddProject || this.canReplaceLatestProject)
    );
  }

  // Fallback when the topic IS a project topic but the viewer can't
  // edit it (e.g., admin without OP rights, or an invalid project
  // payload that fails eligibility). Surfaces a small "coming soon"
  // hint so admins debugging on broken topics still get a signal.
  get showProjectMessageOnly() {
    return (
      this.pluginEnabled &&
      this.isProjectTopic &&
      !this.showProjectActions &&
      (this.isTopicOwner || this.isStaff)
    );
  }

  get projectMessage() {
    switch (this.projectState) {
      case "first":
        return i18n(
          "discourse_revised_critique_image.project_eligible_message"
        );
      case "mixed":
        return i18n(
          "discourse_revised_critique_image.project_can_replace_or_add_message"
        );
      case "atMax":
        return i18n("discourse_revised_critique_image.project_at_max_message");
    }
    return "";
  }

  get projectPrimaryLabel() {
    if (this.projectState === "first") {
      return i18n("discourse_revised_critique_image.project_button_label");
    }
    return i18n(
      "discourse_revised_critique_image.project_replace_latest_label"
    );
  }

  get projectPrimaryMode() {
    return this.projectState === "first" ? "add" : "replace_latest";
  }

  get projectPrimaryIcon() {
    return this.projectState === "first" ? "image" : "arrows-rotate";
  }

  get showProjectAddAnother() {
    return this.projectState === "mixed";
  }

  get projectStateClass() {
    const suffix = this.projectState === "atMax" ? "at-max" : this.projectState;
    return `revised-image-banner__project--${suffix}`;
  }

  @action
  openProjectPrimary() {
    this.openProjectEditor(this.projectPrimaryMode);
  }

  @action
  openProjectAddAnother() {
    this.openProjectEditor("add");
  }

  openProjectEditor(mode) {
    this.modal.show(ProjectRevisionEditor, {
      model: { topic: this.topic, mode },
    });
  }

  <template>
    {{#if this.show}}
      <div
        class="revised-image-banner {{this.stateClass}}"
        data-revised-image-banner-state={{this.state}}
      >
        <p class="revised-image-banner__message">{{this.message}}</p>
        <div class="revised-image-banner__actions">
          <DButton
            class="btn-primary revised-image-banner__button revised-image-banner__primary"
            @action={{this.openPrimary}}
            @icon={{this.primaryButtonIcon}}
            @translatedLabel={{this.primaryButtonLabel}}
          />
          {{#if this.showAddAnotherButton}}
            <DButton
              class="btn-default revised-image-banner__button revised-image-banner__secondary"
              @action={{this.openAddAnother}}
              @icon="plus"
              @label="discourse_revised_critique_image.add_another_label"
            />
          {{/if}}
        </div>
      </div>
    {{else if this.showProjectActions}}
      <div
        class="revised-image-banner revised-image-banner--project
          {{this.projectStateClass}}"
        data-revised-image-banner-state="project"
        data-revised-image-banner-project-state={{this.projectState}}
      >
        <p class="revised-image-banner__message">{{this.projectMessage}}</p>
        <div class="revised-image-banner__actions">
          <DButton
            class="btn-primary revised-image-banner__button revised-image-banner__primary"
            @action={{this.openProjectPrimary}}
            @icon={{this.projectPrimaryIcon}}
            @translatedLabel={{this.projectPrimaryLabel}}
          />
          {{#if this.showProjectAddAnother}}
            <DButton
              class="btn-default revised-image-banner__button revised-image-banner__secondary"
              @action={{this.openProjectAddAnother}}
              @icon="plus"
              @label="discourse_revised_critique_image.project_add_another_label"
            />
          {{/if}}
        </div>
      </div>
    {{else if this.showProjectMessageOnly}}
      <div
        class="revised-image-banner revised-image-banner--project revised-image-banner__project--info-only"
        data-revised-image-banner-state="project"
        data-revised-image-banner-project-state="info-only"
      >
        <p class="revised-image-banner__message">
          {{i18n "discourse_revised_critique_image.project_coming_soon"}}
        </p>
      </div>
    {{/if}}
  </template>
}
