require "test_helper"

class Tunnel::ConnectorChangeTest < ActiveSupport::TestCase
  setup do
    @project = projects(:infra)
  end

  test "edits production's edge config in place: one connector out, one in, nothing else touched" do
    source = file_fixture("edge/production.yml").read
    change = change_for(source, hosts: %w[ kamal-blr-01 kamal-sgp-01 kamal-fra-01 ], secret: "KAMAL_TUNNEL_TOKEN")

    assert change.valid?, change.errors.full_messages.to_sentence
    assert_equal [ "kamal-fra-01" ], change.added
    assert_equal [ "kamal-blr-02" ], change.removed

    after = parse(change.content)
    assert_equal %w[ cloudflared-blr-01 cloudflared-fra-01 cloudflared-sgp-01 ], connectors(after).map { it["name"] }.sort
    assert_equal others(parse(source)), others(after)
    assert_includes change.content, "  cloudflared-fra-01:\n    <<: *cloudflared\n    host: kamal-fra-01\n    options:\n      <<: *cloudflared-options\n      hostname: kamal-fra-01\n"
    assert_includes change.content, "      - kamal-blr-02\n", "the health check and log agent still run there, so it stays listed"
    assert_includes change.content, "      - kamal-fra-01\n"
    assert_equal source.lines.size, change.content.lines.size - 1, "one server listed, six lines out, six in"
    assert_equal [ "kamal accessory remove cloudflared-blr-02 -c deploy/edge.yml -y" ], change.remove_commands
    assert_equal [ "kamal accessory boot cloudflared-fra-01 -c deploy/edge.yml" ], change.boot_commands
  end

  test "edits a generated edge config, keeping its spacing and its server list in step" do
    source = file_fixture("edge/generated.yml").read
    change = change_for(source, hosts: %w[ aps2-az1-node-01 apse1-az1-node-01 euc1-az1-node-01 ])

    assert change.valid?, change.errors.full_messages.to_sentence
    assert_includes change.content, "      hostname: apse1-az1-node-01\n\n  cloudflared-euc1-az1-node-01:\n"
    assert_not_includes change.content, "aps2-az1-node-02"
    assert_equal %w[ aps2-az1-node-01 apse1-az1-node-01 euc1-az1-node-01 ], parse(change.content)["roles"].sole["hosts"]
  end

  test "can move every connector" do
    change = change_for(file_fixture("edge/generated.yml").read, hosts: %w[ use1-az1-node-01 ])

    assert change.valid?, change.errors.full_messages.to_sentence
    assert_equal [ [ "cloudflared-use1-az1-node-01", [ "use1-az1-node-01" ] ] ], connectors(parse(change.content)).map { [ it["name"], it["hosts"] ] }
  end

  test "keeps finding a free name when short names clash, one change after another" do
    source = Tunnel::Setup.for(@project, hosts: %w[ web.sgp.example.com ]).edge_config
    first = change_for(source, hosts: %w[ web.sgp.example.com web.fra.example.com ])
    assert first.valid?, first.errors.full_messages.to_sentence
    assert_equal [ "kamal accessory boot cloudflared-web-2 -c deploy/edge.yml" ], first.boot_commands

    @project.apps.find_by!(config_path: "deploy/edge.yml").update!(accessories: parse(first.content)["accessories"])
    second = change_for(first.content, hosts: %w[ web.sgp.example.com web.fra.example.com web.lon.example.com ])
    assert second.valid?, second.errors.full_messages.to_sentence
    assert_equal [ "kamal accessory boot cloudflared-web-3 -c deploy/edge.yml" ], second.boot_commands
  end

  test "names a connector on an IP after the whole address" do
    source = Tunnel::Setup.for(@project, hosts: %w[ 10.0.0.1 ]).edge_config
    change = change_for(source, hosts: %w[ 10.0.0.1 10.0.0.2 ])

    assert change.valid?, change.errors.full_messages.to_sentence
    assert_includes change.content, "  cloudflared-10-0-0-2:\n    <<: *cloudflared\n    host: 10.0.0.2\n    options:\n      hostname: 10-0-0-2\n"
  end

  test "says what's wrong instead of proposing" do
    source = file_fixture("edge/generated.yml").read
    current = %w[ aps2-az1-node-01 aps2-az1-node-02 apse1-az1-node-01 ]

    assert_includes change_for(source, hosts: current).tap(&:validate).errors.full_messages, "Pick servers to add or remove"
    assert_includes change_for(source, hosts: []).tap(&:validate).errors.full_messages, "Pick at least one server"
  end

  test "refuses a host that isn't plainly a host name before Kamal reads anything" do
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "ran")
      change = change_for(file_fixture("edge/generated.yml").read, hosts: [ "aps2-az1-node-01", "x<%= File::write(#{marker.inspect}, 1) %>", "y\n  evil: 1" ])

      assert_not change.valid?
      assert_match "Not a server name", change.errors.full_messages.to_sentence
      assert_not File.exist?(marker), "ERB in a host ran"
    end
  end

  test "warns about apps the new servers don't run" do
    a = Server.create!(name: "aps2-az1-node-01", hostname: "aps2-az1-node-01", last_seen_at: 1.second.ago)
    shop = @project.apps.create!(service: "shop", config_path: "deploy/shop.yml", hostnames: [ "shop.example.com" ])
    shop.assignments.create!(server: a, role: "web")

    change = change_for(file_fixture("edge/generated.yml").read, hosts: %w[ aps2-az1-node-01 euc1-az1-node-01 ])

    assert_equal [ [ shop, [ "euc1-az1-node-01" ] ] ], change.gaps.map { [ it.app, it.missing ] }
  end

  private
    # The edge config is read from GitHub, so serve this source as the default branch's.
    def change_for(source, hosts:, secret: "CLOUDFLARE_TUNNEL_TOKEN")
      @project.apps.find_or_create_by!(config_path: "deploy/edge.yml", destination: "") do |app|
        app.assign_attributes(service: "edge", kind: App::ACCESSORIES, accessories: parse(source)["accessories"])
      end
      stub_github_files(@project, { "deploy/edge.yml" => source })
      Tunnel::ConnectorChange.new(Tunnel.all.find { it.secret_name == secret }, hosts: hosts)
    end

    def parse(source) = KamalConfig.parse({ "deploy/edge.yml" => source }, [ { "path" => "deploy/edge.yml", "destination" => nil } ]).sole
    def connectors(result) = result["accessories"].select { Tunnel.cloudflared?(it) }
    def others(result) = result["accessories"].reject { Tunnel.cloudflared?(it) }
end
