require "test_helper"

class AppDraftTest < ActiveSupport::TestCase
  setup do
    @project = projects(:infra)
    @servers = [ Server.create!(name: "web-1.example.com", hostname: "web-1.example.com", labels: { "role" => "web" }),
                 Server.create!(name: "web-2.example.com", hostname: "web-2.example.com", labels: { "role" => "web" }) ]
  end

  test "a node app becomes one config and a version file Kamal accepts" do
    draft = build(kind: "node")
    assert draft.valid?, draft.errors.full_messages.to_sentence

    assert_equal %w[ deploy/shop.yml deploy/shop.version ], draft.files.keys
    config = YAML.safe_load(draft.files["deploy/shop.yml"])
    assert_equal 3000, config.dig("proxy", "app_port")
    assert_equal "/up", config.dig("proxy", "healthcheck", "path")
    assert_equal({ "meridian.kind" => "node", "meridian.source" => "example/shop" }, config["labels"])
    assert_equal %w[ web-1.example.com web-2.example.com ], config.dig("servers", "web")
    assert_match "output: \"standalone\"", draft.instructions
  end

  test "a destination splits base and destination files" do
    draft = build(kind: "static", destination: "production")
    assert draft.valid?, draft.errors.full_messages.to_sentence
    assert_equal %w[ deploy/shop.yml deploy/shop.production.yml deploy/shop.production.version ], draft.files.keys
    assert_nil YAML.safe_load(draft.files["deploy/shop.yml"])["servers"]
  end

  test "a tunnel adds a cloudflared accessory to the base config" do
    draft = build(tunnel: true)
    assert draft.valid?, draft.errors.full_messages.to_sentence
    cloudflared = YAML.safe_load(draft.files["deploy/shop.yml"]).dig("accessories", "cloudflared")
    assert_match %r{\Acloudflare/cloudflared:}, cloudflared["image"]
    assert_equal [ "TUNNEL_TOKEN:SHOP_TUNNEL_TOKEN" ], cloudflared.dig("env", "secret")
    assert_nil YAML.safe_load(build.files["deploy/shop.yml"])["accessories"]
  end

  test "a tunnel with a destination keeps the accessory in the base file" do
    draft = build(tunnel: true, destination: "production")
    assert draft.valid?, draft.errors.full_messages.to_sentence
    assert YAML.safe_load(draft.files["deploy/shop.yml"]).dig("accessories", "cloudflared")
    assert_nil YAML.safe_load(draft.files["deploy/shop.production.yml"])["accessories"]
    assert_includes draft.manual_steps.join("\n"), "kamal accessory boot cloudflared -c deploy/shop.yml -d production"
  end

  test "a tunnel replaces the DNS steps with the tunnel steps" do
    steps = build(tunnel: true).manual_steps.join("\n")
    assert_includes steps, "SHOP_TUNNEL_TOKEN=$SHOP_TUNNEL_TOKEN"
    assert_includes steps, "Networking → Tunnels"
    assert_includes steps, "kamal accessory boot cloudflared -c deploy/shop.yml"
    assert_not_includes steps, "Point DNS"
    assert_includes build.manual_steps.join("\n"), "Point DNS"
  end

  test "label selectors pick servers" do
    draft = build(server_ids: [], label_selector: "role=web")
    assert_equal @servers, draft.servers
  end

  test "config paths follow the project's globs" do
    @project.config_globs = [ "config/deploy*.yml" ]
    assert_equal "config/deploy-shop.yml", build.config_path
    @project.config_globs = [ "kamal/*.yml" ]
    assert_equal "kamal/shop.yml", build.config_path
  end

  test "invalid input is refused before Kamal is asked" do
    draft = build(service: "Shop!", hostname: "nope", server_ids: [])
    assert_not draft.valid?
    assert draft.errors.of_kind?(:service, :invalid)
    assert draft.errors.of_kind?(:hostname, :invalid)
    assert_includes draft.errors.full_messages, "Choose at least one server, or a label selector that matches some"
  end

  private
    def build(**attributes)
      AppDraft.new({ project: @project, service: "shop", source_repo: "example/shop", kind: "node", hostname: "shop.example.com", server_ids: @servers.map(&:id) }.merge(attributes))
    end
end
