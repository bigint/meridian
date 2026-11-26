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
      apps = best(App.where("service LIKE ? ESCAPE '\\' OR destination LIKE ? ESCAPE '\\'", pattern, pattern), "service", "length(service) + length(destination)", "service, destination")
      servers = best(Server.where("name LIKE ? ESCAPE '\\' OR hostname LIKE ? ESCAPE '\\'", pattern, pattern), "name")
      projects = best(Project.where("name LIKE ? ESCAPE '\\' OR repo_full_name LIKE ? ESCAPE '\\'", pattern, pattern), "name")

      (apps.map { [ it.name, it, :apps, "App" ] } + servers.map { [ it.name, it, :servers, "Server" ] } + projects.map { [ it.name, it, :projects, "Project" ] })
        .sort_by { |name, *| [ name.downcase.start_with?(@query.downcase) ? 0 : 1, name.length, name ] }.first(LIMIT)
    end

    # The same order as the merged list, in SQL, so the limit keeps the best
    # matches rather than the first ones by name.
    def best(scope, column, length = "length(#{column})", tiebreak = column)
      prefix = "#{ApplicationRecord.sanitize_sql_like(@query)}%"
      scope.order(Arel.sql(ApplicationRecord.sanitize_sql_array([ "#{column} LIKE ? ESCAPE '\\' DESC, #{length}, #{tiebreak}", prefix ]))).limit(LIMIT)
    end
end
