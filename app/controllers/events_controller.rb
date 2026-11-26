class EventsController < ApplicationController
  PER_PAGE = 50

  def index
    @events = Event.recent.includes(:actor)
    @events = @events.where("action LIKE ? ESCAPE '\\'", "#{Event.sanitize_sql_like(params[:action_name].to_s)}%") if params[:action_name].present?
    @events = @events.where(actor_id: params[:actor]) if params[:actor].present?
    @page = [ params[:page].to_s.to_i, 1 ].max
    @events = @events.offset((@page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
    @more = @events.size > PER_PAGE
    @events = @events.first(PER_PAGE)
    @actors = User.order(:email_address)
  end
end
