require "test_helper"

class VersionCellComponentTest < ViewComponent::TestCase
  App = Struct.new(:name)
  Server = Struct.new(:name)

  def cell(state, versions: [ "v42" ], release: "v42")
    Board::Cell.new(app: App.new("web"), server: Server.new("web-1"), state: state, versions: versions, roles: [ "web" ], health: nil, release: release)
  end

  test "shows the running version and says the state in words" do
    render_inline VersionCellComponent.new(cell: cell("in_sync"))
    assert_selector "[data-cell][data-state=in_sync][title='web on web-1: In sync, running v42']", text: "v42"
    assert_selector ".sr-only", text: "In sync"
  end

  test "drifted marks the version it runs instead" do
    render_inline VersionCellComponent.new(cell: cell("drifted", versions: [ "v41" ]))
    assert_selector "[data-state=drifted]", text: "≠v41"
  end

  test "missing and unknown show a symbol, not a version" do
    render_inline VersionCellComponent.new(cell: cell("missing", versions: []))
    assert_selector "[data-state=missing]", text: "✕"
    render_inline VersionCellComponent.new(cell: cell("unknown", versions: []))
    assert_selector "[data-state=unknown]", text: "?"
  end
end
