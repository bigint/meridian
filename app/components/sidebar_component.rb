# The app's navigation. From lg up it is a rail of icons, each named for
# screen readers and on hover; in the phone drawer the names show beside them.
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
        [ "Secrets", helpers.secrets_path, :secrets ]
      ]
    end

    def admin
      @user.admin? ? [ [ "Settings", helpers.settings_root_path, :settings ], [ "Jobs", "/jobs", :jobs ] ] : []
    end

    def current?(path)
      request = helpers.request
      path == helpers.root_path ? request.path.in?([ helpers.root_path, helpers.board_path ]) : request.path.start_with?(path)
    end

    def nav_link(name, path, icon, badge = nil)
      current = current?(path)
      count = badge.to_i
      link_to path, title: name, aria: { current: (current ? "page" : nil) },
        class: classes("relative flex items-center gap-3 rounded-lg px-2.5 py-2 text-sm lg:size-10 lg:justify-center lg:p-0",
          current ? "bg-accent-soft text-accent" : "text-ink-muted hover:bg-raised hover:text-ink") do
        safe_join([
          helpers.icon(icon, class: "size-[18px] shrink-0"),
          tag.span(name, class: "flex-1 lg:sr-only"),
          (tag.span(count, class: "rounded-full bg-bad px-1.5 text-[10px] font-semibold leading-4 text-white lg:absolute lg:-right-1 lg:-top-1",
            aria: { label: "#{helpers.pluralize(count, "thing")} need attention" }) if count.positive?)
        ].compact)
      end
    end
end
