class EventsController < ApplicationController
  PER_PAGE = 50

  def index
    @events = Event.recent.includes(:actor)
    @events = @events.where("action LIKE ? ESCAPE '\\'", "#{Event.sanitize_sql_like(params[:action_name].to_s)}%") if params[:action_name].present?
    # Past the last page, however far (an offset SQLite can't hold), is the last page.
    @page = params[:page].to_s.to_i
    @page = @page > 1 ? @page.clamp(1, [ (@events.count / PER_PAGE.to_f).ceil, 1 ].max) : 1
    @events = @events.offset((@page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
    @more = @events.size > PER_PAGE
    @events = @events.first(PER_PAGE)
  end
end
