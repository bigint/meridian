require "test_helper"

class Ui::TableComponentTest < ViewComponent::TestCase
  Row = Data.define(:name, :version)

  test "one row per record, with header cells" do
    render_inline Ui::TableComponent.new(rows: [ Row.new("web-1", "v1"), Row.new("web-2", "v2") ]) do |table|
      table.with_column("Server", header: true) { it.name }
      table.with_column("Version", mono: true) { it.version }
    end

    assert_selector "thead th", text: "Server"
    assert_selector "thead th", text: "Version"
    assert_selector "tbody tr", count: 2
    assert_selector "tbody th[scope=row]", text: "web-1"
    assert_selector "tbody td", text: "v2"
  end

  test "the empty message when there are no rows" do
    render_inline Ui::TableComponent.new(rows: [], empty: "No servers yet.") do |table|
      table.with_column("Server") { it.name }
    end

    assert_selector "tbody tr", count: 1, text: "No servers yet."
  end
end
