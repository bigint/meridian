require "test_helper"
require "kamal"

# The accessories Meridian hands out for its agent, as Kamal 2.12 boots them.
class TemplatesTest < ActiveSupport::TestCase
  test "the socket proxy and the agent run on their own network, never Kamal's" do
    accessories = YAML.safe_load(Templates.render("kamal/agent-accessories.yml", meridian_url: "https://meridian.example.com", agent_version: "v0.0.0").gsub(/^  /, ""))
    config = Kamal::Configuration.new({ service: "web", image: "acme/web", servers: { "web" => [ "192.0.2.1" ] },
      registry: { "server" => "ghcr.io", "username" => "u", "password" => "p" }, builder: { "arch" => "amd64" },
      accessories: accessories }, version: "0")

    %w[ meridian_docker meridian_agent ].each do |name|
      run = Kamal::Commands::Accessory.new(config, name: name).run.join(" ")
      assert_includes run, "--network meridian", name
      assert_not_includes run, "--network kamal", name
    end
    assert_equal "tcp://web-meridian_docker:2375", accessories.dig("meridian_agent", "env", "clear", "DOCKER_HOST").sub("SERVICE", "web")
    assert_equal "ghcr.io/bigint/meridian-agent:v0.0.0", accessories.dig("meridian_agent", "image")
  end
end
