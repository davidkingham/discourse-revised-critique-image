# frozen_string_literal: true

DiscourseRevisedCritiqueImage::Engine.routes.draw do
  post "/topics/:topic_id/revisions" => "revisions#create"
end
