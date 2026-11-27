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

  test "an app's proxies are kamal-proxy on its servers" do
    elsewhere = server_named("db-1.example.com")
    place(elsewhere, "e" * 64, name: "kamal-proxy", kind: "proxy", service: nil, role: nil)

    assert_equal [ @proxy ], LiveTraffic.proxies(@shop)
  end

  test "a watched app gets its own requests, and nothing else kamal-proxy logged" do
    LiveTraffic.watch(@shop, [ @proxy ])
    lines = [ request("shop-web-production", "/cart"), request("blog-web", "/post"), plain("Service deployed"), plain("not json") ]

    assert_broadcast_on TrafficChannel.broadcasting_for(@shop), { "container" => PROXY, "source" => @proxy.id, "lines" => [ lines.first ] } do
      LiveTraffic.relay(@server, @proxy, { "container" => PROXY, "lines" => lines })
    end
    assert_no_broadcasts TrafficChannel.broadcasting_for(@blog)
  end

  test "traffic is live only: a backlog's requests are history and stop here" do
    LiveTraffic.watch(@shop, [ @proxy ])

    LiveTraffic.relay(@server, @proxy, { "container" => PROXY, "backlog" => true, "lines" => [ request("shop-web-production", "/cart") ] })

    assert_no_broadcasts TrafficChannel.broadcasting_for(@shop)
  end

  test "a request line that repeats a key still counts" do
    line = { "t" => "2026-11-26T12:00:01.000Z", "s" => "out",
      "m" => '{"msg":"Request","path":"/","status":200,"service":"shop-web-production","req_content_type":"","req_content_type":"text/html"}' }
    LiveTraffic.watch(@shop, [ @proxy ])

    assert_broadcasts TrafficChannel.broadcasting_for(@shop), 1 do
      LiveTraffic.relay(@server, @proxy, { "container" => PROXY, "lines" => [ line ] })
    end
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
