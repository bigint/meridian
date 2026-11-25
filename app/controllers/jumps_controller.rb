# "Type to go": the menu's search across apps, servers and projects.
class JumpsController < ApplicationController
  LIMIT = 8

  def show
    @query = params[:q].to_s.strip.first(100)
    @results = @query.present? ? results : []
  end

  private
    def results
      pattern = "%#{ApplicationRecord.sanitize_sql_like(@query)}%"
      apps = App.where("service LIKE ? OR destination LIKE ?", pattern, pattern).ordered.limit(LIMIT).map { [ it.name, it, :apps, "App" ] }
      servers = Server.where("name LIKE ? OR hostname LIKE ?", pattern, pattern).ordered.limit(LIMIT).map { [ it.name, it, :servers, "Server" ] }
      projects = Project.where("name LIKE ? OR repo_full_name LIKE ?", pattern, pattern).order(:name).limit(LIMIT).map { [ it.name, it, :projects, "Project" ] }

      (apps + servers + projects).sort_by { |name, *| [ name.downcase.start_with?(@query.downcase) ? 0 : 1, name.length, name ] }.first(LIMIT)
    end
end
