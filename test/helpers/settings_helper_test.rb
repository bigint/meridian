require "test_helper"

class SettingsHelperTest < ActionView::TestCase
  test "GitHub reads as a token, an App, or not connected" do
    with_env("GITHUB_APP_ID" => nil, "GITHUB_APP_PRIVATE_KEY" => nil, "GITHUB_TOKEN" => "ghp_test") do
      assert_equal [ "Token", nil ], status_of("GitHub")
    end
    with_env("GITHUB_APP_ID" => "123", "GITHUB_TOKEN" => nil) do
      assert_equal [ "App 123", :ok ], status_of("GitHub")
    end
    with_env("GITHUB_APP_ID" => nil, "GITHUB_APP_PRIVATE_KEY" => nil, "GITHUB_TOKEN" => nil) do
      assert_equal [ "Not connected", :bad ], status_of("GitHub")
    end
  end

  test "Kamal shows the version Meridian parses with" do
    assert_equal [ KamalConfig::KAMAL_VERSION, nil ], status_of("Kamal")
  end

  private
    def connection(name) = connections.find { it.name == name }
    def status_of(name) = connection(name).then { [ it.status, it.tone ] }
end
