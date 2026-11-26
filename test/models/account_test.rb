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

  test "preview hostnames are host names, whatever the service is called" do
    assert_equal "pr-12.my-app.preview.example.com", @account.preview_hostname("My_App", 12)

    @account.preview_hostnames = "flat"
    assert_equal "pr-12-my-app.preview.example.com", @account.preview_hostname("my_app", 12)

    long = @account.preview_hostname("my_" + "a" * 60, 1234).delete_suffix(".preview.example.com")
    assert_equal 63, long.length
    assert_match(/\Apr-1234-my-a+-[0-9a-f]{6}\z/, long)
    assert_not_equal long, @account.preview_hostname("my_" + "a" * 61, 1234).delete_suffix(".preview.example.com")
  end
end
