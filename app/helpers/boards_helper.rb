module BoardsHelper
  # One plain sentence per thing that needs attention.
  def attention_sentence(item)
    app = item.app && tag.strong(item.app.name)
    server = item.server && tag.strong(item.server.short_name, title: item.server.name)

    case item.state
    when "missing" then safe_join([ app, " isn't running on ", server, ", but Git says it should." ])
    when "drifted" then safe_join([ app, " on ", server, " runs ", tag.code(item.cell.versions.join(", ")), ", not ", tag.code(item.cell.release), " from Git." ])
    when "stray" then safe_join([ app, " is running on ", server, ", but Git doesn't put it there." ])
    when "stale" then server ? safe_join([ server, "'s agent has gone quiet." ]) : safe_join([ tag.strong(pluralize(item.count, "agent")), " have gone quiet." ])
    end
  end

  def attention_detail(item)
    case item.state
    when "missing" then "Roles: #{item.cell.roles.join(", ")}. A deploy may have failed, or the container stopped."
    when "drifted" then "A deploy may still be rolling out, or it stopped part-way."
    when "stray" then "Remove it, or add the server to the app's config."
    when "stale"
      if item.server then "Last heard from #{time_ago_in_words(item.server.last_seen_at)} ago. #{pluralize(item.count, "app")} can't be checked there until it's back."
      else "Their servers can't be checked until they report again. The Agents page lists them."
      end
    end
  end

  def attention_avatar(item)
    tag.span(Drift::SYMBOLS[item.state], class: "avatar #{item.state}", aria: { hidden: true })
  end

  # The first steps on a new install, ticked off as they happen.
  def getting_started
    [
      [ "Connect your infra repository", "Meridian reads your Kamal configs from it.", new_project_path, Project.exists? ],
      [ "Put the agent on your servers", "So the board shows what really runs, not only what Git says.", agent_tokens_path, Server.where.not(last_seen_at: nil).exists? ],
      [ "Deploy something", "Pick an app, type a version, press Deploy. CI does the rest.", apps_path, Deploy.exists? ]
    ]
  end
end
