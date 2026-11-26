# What a page says when there is nothing to show, and what to do about it.
class Ui::EmptyStateComponent < ApplicationComponent
  renders_one :action

  def initialize(title:, icon: nil)
    @title, @icon = title, icon
  end
end
