# The top of every page: title, a line of context, actions, optional tabs.
class Ui::PageHeaderComponent < ApplicationComponent
  renders_one :description
  renders_one :actions
  renders_one :tabs

  def initialize(title:, subtitle: nil)
    @title, @subtitle = title, subtitle
  end
end
