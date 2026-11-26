# The app's navigation: search, the places people go, and who is signed in.
class SidebarComponent < ApplicationComponent
  def initialize(user:, attention_count: nil)
    @user, @attention_count = user, attention_count
  end

  private
    def primary
      [
        [ "Board", helpers.root_path, :board, @attention_count ],
        [ "Map", helpers.map_path, :map ],
        [ "Apps", helpers.apps_path, :apps ],
        [ "Servers", helpers.servers_path, :servers ],
        [ "Activity", helpers.events_path, :activity ],
        [ "Previews", helpers.previews_path, :previews ]
      ]
    end

    def secondary
      [
        [ "Projects", helpers.projects_path, :projects ],
        [ "Agents", helpers.agent_tokens_path, :agents ],
        [ "Secrets", helpers.secrets_path, :secrets ],
        ([ "Settings", helpers.settings_root_path, :settings ] if @user.admin?),
        ([ "Jobs", "/jobs", :jobs ] if @user.admin?)
      ].compact
    end

    def current?(path)
      request = helpers.request
      path == helpers.root_path ? request.path.in?([ helpers.root_path, helpers.board_path ]) : request.path.start_with?(path)
    end

    def nav_link(name, path, icon, badge = nil)
      current = current?(path)
      link_to path, aria: { current: (current ? "page" : nil) },
        class: classes("flex items-center gap-2.5 rounded-md px-2 py-1.5 text-sm", current ? "bg-raised font-medium text-ink" : "text-ink-muted hover:bg-raised hover:text-ink") do
        safe_join([
          helpers.icon(icon, class: classes("size-4 shrink-0", current ? "text-accent" : "text-ink-faint")),
          tag.span(name, class: "flex-1"),
          (render(Ui::BadgeComponent.new(badge.to_s, tone: :bad)) if badge.to_i.positive?)
        ].compact)
      end
    end
end
