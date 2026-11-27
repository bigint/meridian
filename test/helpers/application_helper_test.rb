require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include IconsHelper
  Named = Struct.new(:name)

  def cell(state, versions: [ "v42" ], release: "v42")
    Board::Cell.new(app: Named.new("web"), server: Named.new("web-1"), state: state, versions: versions, health: nil, release: release, role_states: { "web" => state })
  end

  test "a version cell shows the running version and says the state in words" do
    render html: version_cell(cell("in_sync"))
    assert_select "span.cell[data-cell][data-state=in_sync][data-tooltip=?]", "web on web-1: In sync, running v42", text: /v42/
    assert_select ".cell .sr-only", text: "In sync:"
  end

  test "a drifted cell shows the version it runs; missing and unknown show a symbol" do
    render html: version_cell(cell("drifted", versions: [ "v41" ])) + version_cell(cell("missing", versions: [])) + version_cell(cell("unknown", versions: []))
    assert_select "[data-state=drifted]", text: /≠v41/
    assert_select "[data-state=missing]", text: /#{Drift::SYMBOLS["missing"]}/
    assert_select "[data-state=unknown]", text: /#{Drift::SYMBOLS["unknown"]}/
    assert_select "[data-state=unknown]", text: /\?/, count: 0
  end

  test "every drift state is a symbol and a word, never colour alone" do
    render html: safe_join(Drift::STATES.map { state_badge(it) })
    Drift::STATES.each do |state|
      assert_select ".badge[data-state=#{state}]", text: /#{Regexp.escape(Drift::LABELS[state])}/
      assert_select ".badge[data-state=#{state}] [aria-hidden]", text: Drift::SYMBOLS[state]
    end
  end

  test "no state is a dash" do
    render html: state_badge(nil)
    assert_select "span[data-tooltip='Nothing here']", text: "–"
  end

  test "a chip with an href is a filter that knows when it is on" do
    render html: chip("Drifted", 2, state: "drifted", href: "/?state=drifted", current: true) + chip("All", 3)
    assert_select "a.chip[href='/?state=drifted'][aria-current=true]", text: /Drifted\s*2/
    assert_select "span.chip:not([aria-current])", text: /All\s*3/
  end

  test "avatars use stable initials and are hidden from screen readers" do
    render html: avatar("Ana Lima") + avatar("Ana Lima") + avatar(state: "missing")
    tones = css_select(".avatar[data-tone]").map { it["data-tone"] }
    assert_equal [ "AL", "AL" ], css_select(".avatar[data-tone]").map(&:text)
    assert_equal 1, tones.uniq.size
    assert_select ".avatar[data-state=missing][aria-hidden]", text: Drift::SYMBOLS["missing"]
  end

  test "a segmented control marks the current view" do
    items = [ [ "Grid", "/board", true ], [ "List", "/board?view=list", false ] ]
    render html: segmented("Arrange", items)
    assert_select "nav.segmented[aria-label=Arrange] a[aria-current=true]", text: "Grid"
    assert_select "nav.segmented a:not([aria-current])", text: "List"
  end

  test "pagination appears only when there is another page" do
    assert_nil pagination(label: "1–5 of 5")
    render html: pagination(label: "1–50 of 51", next_url: "/apps?page=2")
    assert_select "nav.pagination a[href='/apps?page=2']", text: "Next"
  end

  test "a titled section is labelled by its heading and can count" do
    render html: titled_section("Releases", count: 3, id: "releases") { "body" }
    assert_select "section.section[aria-labelledby=releases] h2#releases", text: /Releases\s*3/
    assert_select "section", text: /body/
  end

  test "a page header has its title, context and actions" do
    render html: page_header("Servers", meta: "21 servers") { link_to("Add", "/add", class: "btn") }
    assert_select "header.page-header h1", text: "Servers"
    assert_select ".page-header__meta", text: "21 servers"
    assert_select ".page-header__actions a.btn", text: "Add"
  end

  test "a disclosure starts closed unless asked" do
    render html: disclosure("Filters") { "inside" } + disclosure("More", open: true) { "x" }
    assert_select "details.disclosure:not([open]) summary", text: "Filters"
    assert_select "details.disclosure[open] summary", text: "More"
  end

  test "an empty state with a body" do
    render html: empty_state("No apps yet", icon_name: :apps) { "Connect a repository." }
    assert_select ".empty .empty__title", text: "No apps yet"
    assert_select ".empty .empty__body", text: "Connect a repository."
    assert_select ".empty svg"
  end

  test "labels list skips the place labels when asked" do
    render html: labels_list({ "region" => "eu", "role" => "web" }, except: Server::PLACE_LABELS)
    assert_select ".badge--mono", count: 1, text: "role=web"
  end

  test "a docs link opens that page of the docs site" do
    render html: docs_link("The agent", "/guides/agent")
    assert_select "a.link[href=?]", "https://meridian.yoginth.com/guides/agent", text: "The agent"
  end

  test "a proposal is a commit or a pull request" do
    commit = Project::Changes::Proposal.new(url: "https://github.com/example/infra/commit/abc", number: nil, direct: true)
    pull = Project::Changes::Proposal.new(url: "https://github.com/example/infra/pull/5", number: 5, direct: false)

    assert_equal [ "committed", "ready for review" ], [ proposal_state(commit), proposal_state(pull) ]
    render html: proposal_link(commit) + proposal_link(pull)
    assert_select "a.btn--primary[href=?]", commit.url, text: "View commit"
    assert_select "a.btn--primary[href=?]", pull.url, text: "Open pull request #5"
  end
end
