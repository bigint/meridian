require "test_helper"

class IconsHelperTest < ActionView::TestCase
  test "every icon renders a vendored Lucide shape" do
    IconsHelper::ICONS.each_key do |name|
      render html: icon(name)
      assert_select "svg[aria-hidden=true][stroke=currentColor] > *", { minimum: 1 }, "#{name} has no shape"
    end
  end

  test "the logo is Meridian's own mark" do
    render html: icon(:logo, width: 24, height: 24)
    assert_select "svg[width='24'] circle", count: 2
  end
end
