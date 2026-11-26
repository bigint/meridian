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

  test "a label selector term without = is an error, not a crash" do
    assert_equal @servers, build(server_ids: [], label_selector: " role=web, ").servers

    draft = build(server_ids: [], label_selector: "web")
    assert_not draft.valid?
    assert_includes draft.errors[:label_selector], "must be labels like role=web, separated by commas"
    assert_empty draft.servers, "a selector with no usable term matches nothing, not everything"
  end

  test "config paths follow the project's globs" do
    @project.config_globs = [ "config/deploy*.yml" ]
    assert_equal "config/deploy-shop.yml", build.config_path
    @project.config_globs = [ "kamal/*.yml" ]
    assert_equal "kamal/shop.yml", build.config_path
    @project.config_globs = [ "deploy/**/*.yml" ]
    assert_equal "deploy/shop.yml", build.config_path
  end

  test "refuses a config path the project's globs wouldn't sync" do
    @project.config_globs = [ "config/deploy.yml" ]
    draft = build
    assert_not draft.valid?
    assert_includes draft.errors.full_messages, "config/deploy-shop.yml isn't matched by the project's config paths (config/deploy.yml), so Meridian would never see it. Add a path with a * to the project."
  end

  test "invalid input is refused before Kamal is asked" do
    draft = build(service: "Shop!", hostname: "nope", server_ids: [])
    assert_not draft.valid?
    assert draft.errors.of_kind?(:service, :invalid)
    assert draft.errors.of_kind?(:hostname, :invalid)
    assert_includes draft.errors.full_messages, "Choose at least one server, or a label selector that matches some"
  end

  test "never takes over an existing config, whatever the destination" do
    @project.apps.create!(service: "shop", config_path: "deploy/shop.yml", destination: "")
    draft = build(destination: "production")
    assert_not draft.valid?
    assert_includes draft.errors[:service], "already has a config at deploy/shop.yml"

    @project.apps.where(service: "shop").update_all(destination: "staging")
    assert_not build.valid?
  end

  test "refuses a service or a hostname another app already has" do
    @project.update!(config_globs: [ "config/deploy.yml", "deploy/*.yml" ])
    @project.apps.create!(service: "shop", config_path: "config/deploy.yml", hostnames: [ "www.example.com" ])

    draft = build
    assert_not draft.valid?
    assert_includes draft.errors[:service], "is already the service of shop, in config/deploy.yml"

    draft = build(service: "store", hostname: "www.example.com")
    assert_not draft.valid?
    assert_includes draft.errors[:hostname], "is already served by shop"

    assert build(service: "shop", destination: "production").valid?, "a destination names its containers apart"
  end

  test "never overwrites a file already in Git, even one that isn't an app" do
    stub_github_files(@project, { "deploy/shop.yml" => "service: [ broken\n" })
    writes = stub_github_writes(@project)
    draft = build

    assert_not draft.submit(users(:admin))
    assert_includes draft.errors.full_messages, "deploy/shop.yml already exists in example/infra"
    assert_empty writes
  end

  test "a server whose hostname an agent made up is refused, and its ERB never runs" do
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "ran")
      Server.create!(name: "web-9", hostname: "web-9<%= File::write(#{marker.inspect}, 1) %>", labels: { "role" => "web" })

      draft = build(server_ids: [], label_selector: "role=web")
      assert_not draft.valid?
      assert_match "hostnames aren't host names: web-9", draft.errors.full_messages.to_sentence
      assert_not File.exist?(marker), "ERB in a server's hostname ran"
    end
  end

  test "the registry must be a registry host" do
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "ran")
      [ "ghcr.io\n  username: other", "ghcr.io<%= File::write(#{marker.inspect}, 1) %>" ].each do |registry|
        draft = build(registry: registry)
        assert_not draft.valid?
        assert draft.errors.of_kind?(:registry, :invalid)
      end
      assert_not File.exist?(marker)
    end
    assert build(registry: "registry.example.com:5000/team").valid?
  end

  private
    def build(**attributes)
      AppDraft.new({ project: @project, service: "shop", source_repo: "example/shop", kind: "node", hostname: "shop.example.com", server_ids: @servers.map(&:id) }.merge(attributes))
    end
end
