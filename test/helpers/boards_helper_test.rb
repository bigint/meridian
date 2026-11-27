require "test_helper"

class BoardsHelperTest < ActionView::TestCase
  test "server names lose their region prefix under a region heading" do
    server = Struct.new(:name, :short_name).new("aps2-az1-node-01.example.com", "aps2-az1-node-01")
    assert_equal "az1-01", matrix_server_label(server, true)
    assert_equal "aps2-az1-node-01", matrix_server_label(server, false)
    assert_equal "web-1", matrix_server_label(Struct.new(:name, :short_name).new("web-1.example.com", "web-1"), true)
  end

  test "a cell with one role down names that role" do
    named = Struct.new(:name, :short_name)
    cell = Board::Cell.new(app: named.new("shop", "shop"), server: named.new("web-1.example.com", "web-1"), state: "missing", versions: [ "v2" ],
      health: nil, release: "v2", role_states: { "web" => "in_sync", "job" => "missing" })
    item = Board::Attention.new(state: "missing", app: cell.app, server: cell.server, count: 1, cell: cell)

    assert_equal "shop's job role isn't running on web-1, but Git says it should.", CGI.unescapeHTML(strip_tags(attention_sentence(item)))
    assert_match(/\ARole: job\./, attention_detail(item))
  end

  test "deploy tone follows how it went" do
    deploy = Struct.new(:finished?, :succeeded?, :unclaimed?)
    assert_equal :info, deploy_tone(deploy.new(false, false, false))
    assert_equal :warn, deploy_tone(deploy.new(false, false, true))
    assert_equal :ok, deploy_tone(deploy.new(true, true, false))
    assert_equal :bad, deploy_tone(deploy.new(true, false, false))
  end
end
