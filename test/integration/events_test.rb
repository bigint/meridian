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

  test "a deploy's outcome links to its CI run" do
    Event.record("app.deploy.success", actor: nil, by: "Git", summary: "Deploy of web at v42 succeeded", commit: "c" * 40, ci_url: "https://github.com/example/infra/actions/runs/9")

    get events_path
    assert_select ".row__title", text: "Deploy of web at v42 succeeded"
    assert_select ".row__meta", text: /Git/
    assert_select ".row__meta a[href=?]", "https://github.com/example/infra/actions/runs/9", text: "CI run ↗"
  end
end
