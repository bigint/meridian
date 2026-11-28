require "test_helper"

class EventTest < ActiveSupport::TestCase
  test "an event names the person who asked for it" do
    assert_equal users(:ada).display_name, Event.record("app.deploy", actor: users(:ada), summary: "Deployed web").actor_name
  end

  test "an event no person asked for is Meridian's" do
    assert_equal "Meridian", Event.record("project.sync", actor: nil).actor_name
  end

  test "an event no person asked for can say where it came from" do
    assert_equal "Git", Event.record("app.deploy.success", actor: nil, by: "Git").actor_name
  end
end
