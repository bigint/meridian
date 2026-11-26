module BoardsHelper
  # The first steps on a new install, ticked off as they happen.
  def getting_started
    [
      { title: "Connect your infra repository", detail: "Meridian reads your Kamal configs from it.", href: new_project_path, done: Project.exists? },
      { title: "Put the agent on your servers", detail: "So the board shows what really runs, not only what Git says.", href: agent_tokens_path, done: Server.where.not(last_seen_at: nil).exists? },
      { title: "Deploy something", detail: "Pick an app, type a version, press Deploy. CI does the rest.", href: apps_path, done: Deploy.exists? }
    ]
  end
end
