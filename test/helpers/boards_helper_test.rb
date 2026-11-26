require "test_helper"

class BoardsHelperTest < ActionView::TestCase
  test "server names lose their region prefix under a region heading" do
    server = Struct.new(:name, :short_name).new("aps2-az1-node-01.example.com", "aps2-az1-node-01")
    assert_equal "az1-01", matrix_server_label(server, true)
    assert_equal "aps2-az1-node-01", matrix_server_label(server, false)
    assert_equal "web-1", matrix_server_label(Struct.new(:name, :short_name).new("web-1.example.com", "web-1"), true)
  end

  test "deploy tone follows how it went" do
    assert_equal :info, deploy_tone(Struct.new(:finished?, :succeeded?).new(false, false))
    assert_equal :ok, deploy_tone(Struct.new(:finished?, :succeeded?).new(true, true))
    assert_equal :bad, deploy_tone(Struct.new(:finished?, :succeeded?).new(true, false))
  end
end
