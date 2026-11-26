class Ui::ListItemComponent < ApplicationComponent
  renders_one :leading
  renders_one :subtitle
  renders_one :trailing

  def initialize(title: nil, href: nil)
    @title, @href = title, href
  end
end
