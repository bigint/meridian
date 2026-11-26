require "test_helper"

class TunnelTest < ActiveSupport::TestCase
  setup do
    @project = projects(:infra)
    @counter = 0
  end

  test "an accessory is a tunnel by its image" do
    app = make_app("shop", accessories: [ accessory("tunnel", image: "cloudflare/cloudflared:2026.11.2"), accessory("db", image: "postgres:17") ])

    assert_equal [ [ app, "tunnel" ] ], Tunnel.all.map { [ it.app, it.name ] }
  end

  test "an accessory synced before images were reported is a tunnel by the name cloudflared" do
    app = make_app("shop", accessories: [ accessory("cloudflared", image: nil), accessory("db", image: nil) ])

    assert_equal [ [ app, "cloudflared" ] ], Tunnel.all.map { [ it.app, it.name ] }
  end

  test "apps without a tunnel are ignored" do
    make_app("blog", accessories: [ accessory("db", image: "postgres:17") ])

    assert_empty Tunnel.all
  end

  test "a connector is running, stopped, missing or unknown" do
    running, stopped, missing, quiet = %w[ a b c d ].map { server("#{it}.example.com", last_seen_at: 5.seconds.ago) }
    quiet.update!(last_seen_at: 1.hour.ago)
    make_app("shop", accessories: [ accessory("cloudflared", hosts: %w[ a.example.com b.example.com c.example.com d.example.com e.example.com ]) ])
    place(running, "shop-cloudflared", "running")
    place(stopped, "shop-cloudflared", "exited")

    states = Tunnel.all.sole.connectors.to_h { [ it.host, it.state ] }

    assert_equal({ "a.example.com" => :running, "b.example.com" => :stopped, "c.example.com" => :missing, "d.example.com" => :unknown, "e.example.com" => :unknown }, states)
    assert_equal "exited", Tunnel.all.sole.connectors.find { it.state == :stopped }.placement.state
  end

  test "a server that never reported is unknown, not missing" do
    server("a.example.com", last_seen_at: nil)
    make_app("shop", accessories: [ accessory("cloudflared", hosts: [ "a.example.com" ]) ])

    assert_equal :unknown, Tunnel.all.sole.connectors.sole.state
  end

  test "a server is found by hostname or name, and none are created" do
    named = server("web-1", hostname: "10.0.0.1", last_seen_at: 1.second.ago)
    make_app("shop", accessories: [ accessory("cloudflared", hosts: [ "web-1", "10.0.0.2" ]) ])

    assert_no_difference -> { Server.count } do
      connectors = Tunnel.all.sole.connectors
      assert_equal named, connectors.first.server
      assert_nil connectors.last.server
    end
  end

  test "the same accessory on another app's server does not count" do
    web = server("a.example.com", last_seen_at: 1.second.ago)
    make_app("shop", accessories: [ accessory("cloudflared", hosts: [ "a.example.com" ]) ])
    place(web, "blog-cloudflared", "running")

    assert_equal :missing, Tunnel.all.sole.state
  end

  test "problems sort first and set the tunnel's state" do
    web = server("a.example.com", last_seen_at: 1.second.ago)
    other = server("b.example.com", last_seen_at: 1.second.ago)
    make_app("alpha", accessories: [ accessory("cloudflared", hosts: [ "a.example.com" ]) ])
    make_app("beta", accessories: [ accessory("cloudflared", hosts: [ "a.example.com", "b.example.com" ]) ])
    place(web, "alpha-cloudflared", "running")
    place(web, "beta-cloudflared", "running")

    assert_equal %w[ beta alpha ], Tunnel.all.map { it.app.service }
    assert_equal %i[ missing running ], Tunnel.all.map(&:state)
    assert_equal other, Tunnel.all.first.connectors.last.server
  end

  test "the boot command names the config and destination" do
    make_app("shop", destination: "production", accessories: [ accessory("cloudflared") ])
    make_app("blog", accessories: [ accessory("cloudflared") ])

    commands = Tunnel.all.map(&:boot_command)

    assert_includes commands, "kamal accessory boot cloudflared -c deploy/shop.yml -d production"
    assert_includes commands, "kamal accessory boot cloudflared -c deploy/blog.yml"
  end

  test "the query count does not grow with the tunnels" do
    web = server("a.example.com", last_seen_at: 1.second.ago)
    make_app("one", accessories: [ accessory("cloudflared", hosts: [ "a.example.com" ]) ])
    few = count_queries { Tunnel.all }

    10.times { |index| make_app("app#{index}", accessories: [ accessory("cloudflared", hosts: [ "a.example.com", "x#{index}.example.com" ]) ]) }
    place(web, "app3-cloudflared", "running")

    assert_equal few, count_queries { Tunnel.all }
  end

  private
    def make_app(service, destination: "", accessories:)
      @project.apps.create!(service: service, destination: destination, config_path: "deploy/#{service}.yml", accessories: accessories.map { it.merge("service" => "#{service}-#{it["name"]}") })
    end

    def accessory(name, image: "cloudflare/cloudflared:2026.11.2", hosts: [ "a.example.com" ])
      { "name" => name, "image" => image, "hosts" => hosts }.compact
    end

    def server(name, hostname: name, last_seen_at:)
      Server.create!(name: name, hostname: hostname, last_seen_at: last_seen_at)
    end

    def place(server, service, state)
      server.placements.create!(container_id: "c#{@counter += 1}", name: service, kind: "accessory", service: service, state: state, observed_at: Time.current)
    end

    def count_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
end
