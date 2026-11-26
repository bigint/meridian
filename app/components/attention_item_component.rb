# One thing that needs attention, in a plain sentence, with what it means
# and where to go next.
class AttentionItemComponent < ApplicationComponent
  def initialize(item:)
    @item = item
  end

  def call
    render Ui::ListItemComponent.new do |row|
      row.with_leading { render Ui::AvatarComponent.new(state: @item.state) }
      row.with_subtitle { detail }
      row.with_trailing { action }
      sentence
    end
  end

  private
    def sentence
      app = @item.app && tag.strong(@item.app.name, class: "font-semibold")
      server = @item.server && tag.strong(@item.server.short_name, title: @item.server.name, class: "font-mono font-medium")

      case @item.state
      when "missing" then safe_join([ app, " isn't running on ", server, ", but Git says it should." ])
      when "drifted" then safe_join([ app, " on ", server, " runs ", tag.code(@item.cell.versions.join(", ")), ", not ", tag.code(@item.cell.release), " from Git." ])
      when "stray" then safe_join([ app, " is running on ", server, ", but Git doesn't put it there." ])
      when "stale"
        server ? safe_join([ server, "'s agent has gone quiet." ]) : safe_join([ tag.strong(helpers.pluralize(@item.count, "agent")), " have gone quiet." ])
      end
    end

    def detail
      case @item.state
      when "missing" then "Roles: #{@item.cell.roles.join(", ")}. A deploy may have failed, or the container stopped."
      when "drifted" then "A deploy may still be rolling out, or it stopped part-way."
      when "stray" then "Remove it, or add the server to the app's config."
      when "stale"
        if @item.server
          "Last heard from #{helpers.time_ago_in_words(@item.server.last_seen_at)} ago. #{helpers.pluralize(@item.count, "app")} can't be checked there until it's back."
        else
          "Their servers can't be checked until they report again. The Agents page lists them."
        end
      end
    end

    def action
      if @item.app then render Ui::ButtonComponent.new(label: "Open #{@item.app.service}", href: helpers.app_path(@item.app), size: :sm)
      elsif @item.server then render Ui::ButtonComponent.new(label: "Open server", href: helpers.server_path(@item.server), size: :sm)
      else render Ui::ButtonComponent.new(label: "See agents", href: helpers.agent_tokens_path, size: :sm)
      end
    end
end
