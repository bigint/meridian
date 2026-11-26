# Term and value pairs: configuration, facts about a server.
class Ui::DescriptionListComponent < ApplicationComponent
  class Item < ApplicationComponent
    attr_reader :term

    def initialize(term)
      @term = term
    end

    def call = content
  end

  renders_many :items, Item

  def call
    tag.dl class: "grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2 text-sm" do
      safe_join(items.map { |item| tag.dt(item.term, class: "text-ink-muted") + tag.dd(item, class: "min-w-0 break-words text-ink") })
    end
  end
end
