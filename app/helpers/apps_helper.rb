module AppsHelper
  # Every server as [ name, id ], grouped under its region for a grouped select.
  def server_options_by_region
    Server.ordered.group_by { it.label("region") || "unlabelled" }.sort.map { |region, servers| [ region, servers.map { [ it.name, it.id ] } ] }
  end
end
