# frozen_string_literal: true

DiscourseRevisedCritiqueImage::Engine.routes.draw do
  post "/topics/:topic_id/revisions" => "revisions#create"
  post "/topics/:topic_id/project-revisions" => "project_revisions#create"
end
