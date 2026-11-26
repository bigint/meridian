require "test_helper"

class EventTest < ActiveSupport::TestCase
  test "an event still names its actor after that person is removed" do
    user = User.create!(email_address: "leaver@example.com", password: "a long enough password", role: "deployer", name: "Lee")
    event = Event.record("app.deploy", actor: user, summary: "Deployed web")
    assert_equal user.display_name, event.actor_name

    user.destroy!
    assert_equal "#{user.display_name} (removed)", event.reload.actor_name
  end

  test "an event no person asked for is Meridian's" do
    assert_equal "Meridian", Event.record("project.sync", actor: nil).actor_name
  end
end
