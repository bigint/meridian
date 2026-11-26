# A titled block of a page.
class Ui::SectionComponent < ApplicationComponent
  renders_one :actions

  def initialize(title:, count: nil, id: nil)
    @title, @count, @id = title, count, id || "section-#{title.parameterize}"
  end
end
