class PreviewsController < ApplicationController
  def index
    @previews = Preview.current.includes(app: :project).ordered
    @recent = Preview.removed.includes(:app).order(updated_at: :desc).limit(10)
  end
end
