# A list of rows: something on the left, a title and a line under it,
# something on the right. Activity, releases, attention items.
class Ui::ListComponent < ApplicationComponent
  renders_many :items, Ui::ListItemComponent

  def initialize(**html)
    @html = html
  end

  def call
    tag.ul class: classes("divide-y divide-line rounded-lg border border-line", @html.delete(:class)), **@html do
      items? ? safe_join(items) : content
    end
  end
end
