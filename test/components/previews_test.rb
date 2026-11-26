require "test_helper"

# Every Lookbook preview renders, so the gallery never rots.
class ComponentPreviewsTest < ViewComponent::TestCase
  ViewComponent::Preview.all.each do |preview|
    preview.examples.each do |example|
      test "#{preview.preview_name} #{example} renders" do
        render_preview(example, from: preview)
        assert page.has_css?("*")
      end
    end
  end
end
