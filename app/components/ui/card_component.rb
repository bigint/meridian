# A bordered surface. No shadows anywhere.
class Ui::CardComponent < ApplicationComponent
  renders_one :header
  renders_one :footer

  def initialize(title: nil, padded: true, **html)
    @title, @padded, @html = title, padded, html
  end
end
