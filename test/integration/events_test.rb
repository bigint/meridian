require "test_helper"

class EventsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:ada) }

  test "a page past the last, however big, shows the last" do
    51.times { Event.record("app.deploy", actor: nil, summary: "Deployed") }

    get events_path(page: "99999999999999999999999")
    assert_response :success
    assert_select ".row__title", text: "Deployed", count: 1
    assert_equal [ "/events?page=1" ], css_select(".pagination a").map { it["href"] }
  end
end
