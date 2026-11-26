class ApplicationController < ActionController::Base
  include Authentication
  include Authorization

  default_form_builder MeridianFormBuilder

  allow_browser versions: :modern
  stale_when_importmap_changes
end
