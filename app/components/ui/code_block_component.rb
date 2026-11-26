# Code to copy: install snippets, generated configs.
class Ui::CodeBlockComponent < ApplicationComponent
  def initialize(code:, label: nil)
    @code, @label = code, label
  end

  def call
    tag.div class: "overflow-hidden rounded-lg border border-line", data: { controller: "clipboard" } do
      tag.div(class: "flex items-center justify-between border-b border-line bg-surface px-3 py-1.5") do
        tag.span(@label, class: "font-mono text-xs text-ink-muted") +
          tag.button("Copy", type: "button", class: "text-xs font-medium text-ink-muted hover:text-ink cursor-pointer",
            data: { action: "clipboard#copy", clipboard_target: "button" })
      end + tag.pre(tag.code(@code, data: { clipboard_target: "source" }), class: "overflow-x-auto bg-canvas p-3 font-mono text-xs leading-relaxed text-ink")
    end
  end
end
