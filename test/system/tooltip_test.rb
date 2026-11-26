require "application_system_test_case"

class TooltipTest < ApplicationSystemTestCase
  setup do
    stub_github_repo(projects(:infra))
    projects(:infra).sync
    sign_in users(:viewer)
  end

  test "hovering a server on the board names it in full, and leaving hides it" do
    find("[data-board-grid] thead th a", text: "web-1").hover
    assert_selector "[role=tooltip]", text: "web-1.example.com"

    find("h1").hover
    assert_no_selector "[role=tooltip]"
  end

  test "a tooltip shows on keyboard focus, describes its element, and Escape hides it" do
    link = find("[data-board-grid] thead th a", text: "web-1")
    find("body").send_keys(:shift) # the last input is the keyboard's, so focus shows as :focus-visible
    page.execute_script("arguments[0].focus()", link)

    assert_selector "[role=tooltip]", text: "web-1.example.com"
    assert_equal "tooltip", link["aria-describedby"]

    send_keys :escape
    assert_no_selector "[role=tooltip]"
    assert_nil link["aria-describedby"]
  end

  test "the sidebar names its icons only once it is a rail" do
    find("#sidebar a", text: "Map").hover
    assert_no_selector "[role=tooltip]", wait: 1

    click_on "Collapse sidebar"
    sleep 0.05 until rect("#sidebar")["width"] < 80
    find("#sidebar a[data-tooltip=Map]").hover
    assert_selector "[role=tooltip]", text: "Map"
    assert_operator rect("#tooltip")["left"], :>, rect("#sidebar a[data-tooltip=Map]")["right"], "beside the rail, not over the icon above"
  end

  private
    def rect(selector) = page.evaluate_script("document.querySelector(#{selector.to_json}).getBoundingClientRect().toJSON()")
end
