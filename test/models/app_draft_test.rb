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

  test "behind the project's tunnel, kamal-proxy logs who asked and through which Cloudflare location" do
    assert_nil YAML.safe_load(build.files["deploy/shop.yml"]).dig("proxy", "logging")

    @project.apps.create!(service: "edge", kind: App::ACCESSORIES, config_path: "deploy/edge.yml",
      accessories: [ { "name" => "cloudflared", "service" => "edge-cloudflared", "image" => "cloudflare/cloudflared:2026.11.2", "hosts" => [ "web-1.example.com" ], "secrets" => [ "CLOUDFLARE_TUNNEL_TOKEN" ] } ])

    config = YAML.safe_load(build.files["deploy/shop.yml"])
    assert_equal %w[ Cf-Connecting-Ip Cf-Ipcountry Cf-Ray ], config.dig("proxy", "logging", "request_headers")
    assert_equal "/up", config.dig("proxy", "healthcheck", "path")
  end

  test "a destination splits base and destination files" do
    draft = build(kind: "static", destination: "production")
    assert draft.valid?, draft.errors.full_messages.to_sentence
    assert_equal %w[ deploy/shop.yml deploy/shop.production.yml deploy/shop.production.version ], draft.files.keys
    assert_nil YAML.safe_load(draft.files["deploy/shop.yml"])["servers"]
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
