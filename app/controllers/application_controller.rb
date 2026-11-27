class ApplicationController < ActionController::Base
  include Authentication

  allow_browser versions: :modern
  stale_when_importmap_changes

  private
    def github_refused(error)
      "GitHub refused: #{error.message.truncate(200)}"
    end
end
