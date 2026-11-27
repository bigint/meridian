require "test_helper"

class ShellTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:ada) }

  test "the sidebar names its places, counts what needs attention and offers to collapse" do
    get root_path
    assert_select ".shell:not([data-collapsed])"
    assert_select "#sidebar nav[aria-label=Main] a.sidebar__link[aria-current=page][data-tooltip=Board]", text: /Board/
    assert_select "#sidebar nav[aria-label=Main] a", 5
    assert_select "#sidebar nav[aria-label=Manage] a[href=?]", tunnels_path, text: "Tunnels"
    assert_select "#sidebar nav[aria-label=Manage] a", text: /Secrets/
    assert_select "#sidebar nav[aria-label=System] a[data-tooltip=Settings]", text: /Settings/
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
    assert_select "#topbar button[popovertarget=account][aria-label=?]", "Account: #{users(:ada).display_name}"
    assert_select "#account[popover] form[action='/session'] button", text: /Sign out/
  end

  test "the theme follows the system until someone picks one, and is rendered from the cookie" do
    get root_path
    assert_select "html:not([data-theme])"
    assert_select "#account [data-controller=theme] button[data-theme-choice=system][aria-pressed=true]"

    cookies[:theme] = "dark"
    get root_path
    assert_select "html[data-theme=dark]"
    assert_select "#account button[data-theme-choice=dark][aria-pressed=true]"

    cookies[:theme] = "purple"
    get root_path
    assert_select "html:not([data-theme])", { count: 1 }, "only light and dark are honoured"
  end

  test "no view uses an inline style, which the CSP would block" do
    offenders = Dir[Rails.root.join("app/views/**/*.erb")].select { File.read(it).match?(/\sstyle="/) }
    assert_empty offenders.map { it.delete_prefix("#{Rails.root}/") }
  end
end
