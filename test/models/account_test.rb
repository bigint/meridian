require "test_helper"

class AccountTest < ActiveSupport::TestCase
  setup { @account = accounts(:main) }

  test "the preview selector is labels, with stray spaces and commas ignored" do
    @account.update!(preview_selector: " role=preview, region=sg ,")
    assert_equal({ "role" => "preview", "region" => "sg" }, @account.preview_labels)
  end

  test "a preview selector term that isn't key=value is refused" do
    [ "preview", "role=", "=preview", "role=preview web" ].each do |selector|
      @account.preview_selector = selector
      assert_not @account.valid?, selector.inspect
      assert_includes @account.errors[:preview_selector], "must be labels like role=preview, separated by commas"
    end
  end
end
