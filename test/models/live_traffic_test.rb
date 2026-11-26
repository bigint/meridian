require "test_helper"

class LiveTrafficTest < ActiveSupport::TestCase
  include MemoryCacheHelper
  include ActionCable::TestHelper

  PROXY = "f" * 64

  setup do
    @server = server_named("web-1.example.com")
    @shop = App.create!(project: projects(:infra), service: "shop", destination: "production", config_path: "deploy/shop.yml", kind: "node",
      roles: [ { "name" => "web", "hosts" => [ "web-1.example.com" ] } ])
    @blog = App.create!(project: projects(:infra), service: "blog", config_path: "deploy/blog.yml", kind: "static")
    place(@server, WEB, app: @shop, name: "shop-web-production-v1", service: "shop")
    place(@server, WORKER, app: @blog, name: "blog-web-v1", service: "blog")
    @proxy = place(@server, PROXY, name: "kamal-proxy", kind: "proxy", service: nil, role: nil)
  end

  test "an app's services are Kamal's container prefixes, previews included" do
    @shop.previews.create!(pr_number: 12, destination: "pr-12", hostname: "pr-12.shop.example.com", overlay_path: "deploy/shop.pr-12.yml", expires_at: 1.day.from_now)

    assert_equal Set.new(%w[ shop-web-production shop-web-pr-12 ]), LiveTraffic.services(@shop)
    assert_equal Set.new(%w[ blog-web ]), LiveTraffic.services(@blog)
  end

  test "an app's proxies are kamal-proxy on its servers" do
    elsewhere = server_named("db-1.example.com")
    place(elsewhere, "e" * 64, name: "kamal-proxy", kind: "proxy", service: nil, role: nil)

    assert_equal [ @proxy ], LiveTraffic.proxies(@shop)
  end

  test "a watched app gets its own requests, and nothing else kamal-proxy logged" do
    LiveTraffic.watch(@shop, [ @proxy ])
    lines = [ request("shop-web-production", "/cart"), request("blog-web", "/post"), plain("Service deployed"), plain("not json") ]

    assert_broadcast_on TrafficChannel.broadcasting_for(@shop), { "container" => PROXY, "source" => @proxy.id, "backlog" => true, "lines" => [ lines.first ] } do
      LiveTraffic.relay(@server, @proxy, { "container" => PROXY, "backlog" => true, "lines" => lines })
    end
    assert_no_broadcasts TrafficChannel.broadcasting_for(@blog)
  end

  test "a batch with none of a watched app's requests sends that app nothing" do
    LiveTraffic.watch(@shop, [ @proxy ])

    LiveTraffic.relay(@server, @proxy, { "container" => PROXY, "lines" => [ request("blog-web", "/post") ] })

    assert_no_broadcasts TrafficChannel.broadcasting_for(@shop)
  end

  test "kamal-proxy's notices reach every app being read on its server" do
    LiveTraffic.watch(@shop, [ @proxy ])
    LiveTraffic.watch(@blog, [ @proxy ])

    [ @shop, @blog ].each do |app|
      assert_broadcast_on(TrafficChannel.broadcasting_for(app), { "container" => PROXY, "source" => @proxy.id, "off" => true }) do
        LiveTraffic.relay(@server, @proxy, { "container" => PROXY, "off" => true })
      end
    end
  end

  test "nothing is relayed once nobody reads, or for a server nobody reads" do
    LiveTraffic.relay(@server, @proxy, { "container" => PROXY, "lines" => [ request("shop-web-production", "/") ] })
    assert_no_broadcasts TrafficChannel.broadcasting_for(@shop)

    LiveTraffic.watch(@shop, [ @proxy ])
    travel LiveLogs::LEASE + 1.second
    LiveTraffic.relay(@server, @proxy, { "container" => PROXY, "lines" => [ request("shop-web-production", "/") ] })
    assert_no_broadcasts TrafficChannel.broadcasting_for(@shop)
  end

  private
    def request(service, path)
      { "t" => "2026-11-26T12:00:01.000Z", "s" => "out", "m" => { time: "2026-11-26T12:00:01Z", level: "INFO", msg: "Request", path: path, status: 200, service: service }.to_json }
    end

    def plain(message)
      { "t" => "2026-11-26T12:00:01.000Z", "s" => "out", "m" => message.start_with?("not") ? message : { level: "INFO", msg: message, service: "shop-web-production" }.to_json }
    end
end
