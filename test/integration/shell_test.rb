require "test_helper"

class ShellTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:admin) }

  test "the sidebar names its places, counts what needs attention and offers to collapse" do
    get root_path
    assert_select ".shell:not([data-collapsed])"
    assert_select "#sidebar nav[aria-label=Main] a.sidebar__link[aria-current=page][title=Board]", text: /Board/
    assert_select "#sidebar a[title=Settings]"
    assert_select "#sidebar button.sidebar__toggle[aria-expanded=true][aria-label='Collapse sidebar']"
  end

  test "a collapsed sidebar is rendered collapsed, with no flicker" do
    cookies[:sidebar] = "collapsed"
    get root_path
    assert_select ".shell[data-collapsed]"
    assert_select "#sidebar button.sidebar__toggle[aria-expanded=false][aria-label='Expand sidebar']"
  end

  test "the top bar searches and holds the account menu" do
    get root_path
    assert_select "#topbar form[action=?] input[type=search][name=q]", jump_path
    assert_select "#topbar label.sr-only", text: "Search apps, servers and projects"
    assert_select "#topbar button[popovertarget=account][aria-label=?]", "Account: #{users(:admin).display_name}"
    assert_select "#account[popover] form[action='/session'] button", text: /Sign out/
  end

  test "no view uses an inline style, which the CSP would block" do
    offenders = Dir[Rails.root.join("app/views/**/*.erb")].select { File.read(it).match?(/\sstyle="/) }
    assert_empty offenders.map { it.delete_prefix("#{Rails.root}/") }
  end
end
