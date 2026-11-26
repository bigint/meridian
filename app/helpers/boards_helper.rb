module BoardsHelper
  # The first steps on a new install, ticked off as they happen.
  def getting_started
    [
      { title: "Connect your infra repository", detail: "Meridian reads your Kamal configs from it.", href: new_project_path, done: Project.exists? },
      { title: "Put the agent on your servers", detail: "So the board shows what really runs, not only what Git says.", href: agent_tokens_path, done: Server.where.not(last_seen_at: nil).exists? },
      { title: "Deploy something", detail: "Pick an app, type a version, press Deploy. CI does the rest.", href: apps_path, done: Deploy.exists? }
    ]
  end

  # One thing that needs attention, as a plain sentence.
  def attention_sentence(item)
    app = item.app && tag.strong(item.app.name)
    server = item.server && tag.strong(item.server.short_name, class: "mono", data: { tooltip: item.server.name })

    case item.state
    when "missing"
      if item.cell.role_states.values.all?("missing")
        safe_join([ app, " isn't running on ", server, ", but Git says it should." ])
      else
        safe_join([ app, "'s ", tag.code(item.cell.roles_in("missing").join(", ")), " role isn't running on ", server, ", but Git says it should." ])
      end
    when "drifted" then safe_join([ app, " on ", server, " runs ", tag.code(item.cell.versions.join(", ")), ", not ", tag.code(item.cell.release), " from Git." ])
    when "stray"
      if item.cell.role_states.values.all?("stray")
        safe_join([ app, " is running on ", server, ", but Git doesn't put it there." ])
      else
        safe_join([ app, " runs its ", tag.code(item.cell.roles_in("stray").compact.join(", ").presence || "unnamed"), " role on ", server, ", but Git doesn't put that role there." ])
      end
    when "stale"
      server ? safe_join([ server, "'s agent has gone quiet." ]) : safe_join([ tag.strong(pluralize(item.count, "agent")), " have gone quiet." ])
    end
  end

  # What it probably means.
  def attention_detail(item)
    case item.state
    when "missing" then "#{"Role".pluralize(item.cell.roles_in("missing").size)}: #{item.cell.roles_in("missing").join(", ")}. A deploy may have failed, or the container stopped."
    when "drifted" then "A deploy may still be rolling out, or it stopped part-way."
    when "stray" then "Remove it, or add the server to the app's config."
    when "stale"
      if item.server
        "Last heard from #{time_ago_in_words(item.server.last_seen_at)} ago. #{pluralize(item.count, "app")} can't be checked there until it's back."
      else
        "Their servers can't be checked until they report again. The Agents page lists them."
      end
    end
  end

  # Where to go next.
  def attention_action(item)
    if item.app then link_to "Open #{item.app.service}", app_path(item.app), class: "btn btn--small"
    elsif item.server then link_to "Open server", server_path(item.server), class: "btn btn--small"
    else link_to "See agents", agent_tokens_path, class: "btn btn--small"
    end
  end

  # Every placement of an app, as board cells.
  def app_cells(app)
    group = Board.new(app_id: app.id, group: "none").groups.first
    group ? group.columns.map { group.cell(app, it) }.compact : []
  end

  # One line that answers "is this app running what Git says?"
  def app_status(app, cells)
    return tag.span("Not assigned to any server yet.", class: "txt-muted") if cells.empty?
    return badge("No version file yet, so Meridian can't compare versions.") unless app.versioned?

    release = app.latest_release&.version
    running = cells.count { it.versions.include?(release) }
    quiet = cells.count { it.state == "stale" }

    status = if running == cells.size
      badge("✓ Running #{release} everywhere", tone: :ok)
    else
      badge("#{running} of #{pluralize(cells.size, "server")} run #{release}", tone: :warn)
    end
    quiet.zero? ? status : status + tag.span(" · #{pluralize(quiet, "agent")} quiet, last report may be old", class: "txt-small txt-muted")
  end

  # Under a region heading the region part of a name is noise:
  # "aps2-az1-node-01" reads as "az1-01".
  def matrix_server_label(server, grouped)
    name = server.try(:short_name) || server.name
    parts = name.split("-")
    grouped && parts.size > 2 ? (parts.drop(1) - [ "node" ]).join("-") : name
  end

  def matrix_group_title(board, group)
    group.name || (board.group_by ? "No #{board.group_by}" : "All servers")
  end

  # The newest release of an app, from any of its cells.
  def matrix_release(board, app)
    board.groups.each { |group| group.cells.each_value { |cell| return cell.release if cell.app == app } }
    nil
  end

  def deploy_heading(deploy)
    verb = { "rollback" => "Rollback to", "redeploy" => "Redeploy of" }.fetch(deploy.kind, "Deploy of")
    safe_join([ verb, " ", tag.code(deploy.version), " · ", deploy.state_label ])
  end

  def deploy_tone(deploy)
    return :info unless deploy.finished?
    deploy.succeeded? ? :ok : :bad
  end
end
