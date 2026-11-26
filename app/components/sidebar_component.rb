# The app's navigation. From lg up it is a sidebar with names, which the «
# button collapses to a rail of icons (named on hover and for screen
# readers); » brings it back. On phones it is the drawer, always with names.
#
# Collapsed styles hang off the shell's data-collapsed attribute
# (group/shell in the layout), so the toggle needs no re-render.
class SidebarComponent < ApplicationComponent
  def initialize(user:, attention_count: nil, collapsed: false)
    @user, @attention_count, @collapsed = user, attention_count, collapsed
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

    def toggle_button(label:, icon:, css:, role:)
      tag.button helpers.icon(icon, class: "size-4"), type: "button", title: label, aria: { label: label, expanded: (!@collapsed).to_s },
        data: { action: "sidebar#toggle", sidebar_toggle: role },
        class: classes("size-8 place-items-center rounded-md text-ink-muted hover:bg-raised hover:text-ink cursor-pointer", css)
    end

    def nav_link(name, path, icon, badge = nil)
      current = current?(path)
      count = badge.to_i
      link_to path, title: name, aria: { current: (current ? "page" : nil) },
        class: classes("relative flex items-center gap-3 rounded-lg px-2.5 py-2 text-sm",
          "lg:group-data-[collapsed]/shell:size-10 lg:group-data-[collapsed]/shell:justify-center lg:group-data-[collapsed]/shell:p-0",
          current ? "bg-accent-soft font-medium text-accent" : "text-ink-muted hover:bg-raised hover:text-ink") do
        safe_join([
          helpers.icon(icon, class: "size-[18px] shrink-0"),
          tag.span(name, class: "flex-1 truncate lg:group-data-[collapsed]/shell:sr-only"),
          (tag.span(count, class: "rounded-full bg-bad px-1.5 text-[10px] font-semibold leading-4 text-white lg:group-data-[collapsed]/shell:absolute lg:group-data-[collapsed]/shell:-right-1 lg:group-data-[collapsed]/shell:-top-1",
            aria: { label: "#{helpers.pluralize(count, "thing")} need attention" }) if count.positive?)
        ].compact)
      end
    end
end
