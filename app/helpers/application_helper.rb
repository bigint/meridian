module ApplicationHelper
  # The six places in the menu's tiles, reachable with 1–6 while it is open.
  def jump_places
    [
      [ "Board", root_path, :board, "b" ],
      [ "Apps", apps_path, :apps, "a" ],
      [ "Servers", servers_path, :servers, "s" ],
      [ "Activity", events_path, :activity, "e" ],
      [ "Previews", previews_path, :previews, "v" ],
      [ "Agents", agent_tokens_path, :agents, "g" ]
    ]
  end

  def jump_more
    [
      [ "Projects", projects_path, :projects, "p" ],
      [ "Secrets", secrets_path, :secrets, "k" ],
      ([ "Settings", settings_root_path, :settings ] if current_user.admin?),
      ([ "Jobs", "/jobs", :jobs ] if current_user.admin?)
    ].compact
  end

  def current_place?(path)
    path == root_path ? (current_page?(root_path) || current_page?(board_path)) : request.path.start_with?(path)
  end

  def drift_badge(state)
    return tag.span("–", class: "state unknown", title: "Nothing here") unless state
    tag.span class: "state #{state}" do
      safe_join([ tag.span(Drift::SYMBOLS[state], aria: { hidden: true }), Drift::LABELS[state] ], " ")
    end
  end

  def health_text(health)
    case health
    when "healthy" then "healthy"
    when "unhealthy" then tag.strong("unhealthy", class: "state missing")
    when "starting" then "starting"
    end
  end

  def time_ago(time)
    return tag.span("never", class: "muted") unless time
    tag.time("#{time_ago_in_words(time)} ago", datetime: time.iso8601, title: time.to_fs(:long))
  end

  def short_sha(sha)
    tag.code(sha.to_s.first(7))
  end

  def labels_list(labels)
    safe_join(labels.sort.map { |key, value| tag.span("#{key}=#{value}", class: "tag") }, " ")
  end
end
