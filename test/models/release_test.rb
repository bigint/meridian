require "test_helper"

class ReleaseTest < ActiveSupport::TestCase
  setup do
    @app = projects(:infra).apps.create!(service: "shop", config_path: "deploy/shop.yml", version_path: "deploy/shop.version")
  end

  # A rebase-merged pull request lands its commits in the same second, and
  # GitHub lists them newest first.
  test "of releases committed in the same second, the one GitHub lists first is the newest" do
    landed = 1.hour.ago.change(usec: 0)
    @app.record_releases([
      { version: "v3", commit_sha: "c" * 40, committed_at: landed },
      { version: "v2", commit_sha: "b" * 40, committed_at: landed },
      { version: "v1", commit_sha: "a" * 40, committed_at: 2.hours.ago }
    ])

    assert_equal %w[ v3 v2 v1 ], @app.releases.map(&:version)
    assert_equal "v3", @app.latest_release.version
    assert_equal [ "v3" ], Release.latest_per_app.where(app: @app).pluck(:version), "one newest release per app"
  end

  test "a later sync's release in the same second is newer still" do
    landed = 1.hour.ago.change(usec: 0)
    @app.record_releases([ { version: "v1", commit_sha: "a" * 40, committed_at: landed } ])
    @app.record_releases([ { version: "v2", commit_sha: "b" * 40, committed_at: landed } ])

    assert_equal "v2", @app.reload.latest_release.version
    assert_equal [ "v2" ], Release.latest_per_app.where(app: @app).pluck(:version)
  end
end
