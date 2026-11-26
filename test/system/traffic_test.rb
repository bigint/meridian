require "application_system_test_case"

# An app's Traffic page: the browser subscribes to TrafficChannel, which
# watches the app, and what kamal-proxy relays is filtered to the app's own
# requests before it reaches the page.
class TrafficTest < ApplicationSystemTestCase
  include MemoryCacheHelper

  setup do
    @app = App.create!(project: projects(:infra), service: "shop", destination: "production", config_path: "deploy/shop.yml", kind: "node",
      hostnames: [ "shop.example.com" ])
    @servers = [ server_named("web-1.example.com"), server_named("web-2.example.com") ]
    @proxies = @servers.each_with_index.map do |server, i|
      place(server, "#{i + 1}" * 64, app: @app, name: "shop-web-production-1a2b3c4d5e6f", service: "shop", version: "1a2b3c4d5e6f")
      place(server, "#{i + 7}" * 64, name: "kamal-proxy", kind: "proxy", service: nil, role: nil)
    end
    use_async_cable
  end

  teardown do
    restore_cable
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ])
  end

  test "each server's kamal-proxy sends the app's requests, and only those" do
    sign_in users(:deployer)
    visit app_path(@app)
    click_on "Traffic"
    assert_selector ".logs[data-state=live]"
    assert_text "No requests yet."
    assert_no_button "stderr"

    relay 0, request("12:00:01", "/", 200, 4_100_000, "1" * 12), request("12:00:01.5", "/admin", 200, 1_000_000, "9" * 12, service: "blog-web")
    relay 1, request("12:00:02", "/cart", 502, 30_012_000_000, "2" * 12, ray: "8f1c2d3e4f5a6b7c-FRA", country: "DE")
    relay 0, request("12:00:03", "/missing", 404, 812_000, "1" * 12, ray: "8f1c2d3e4f5a6b7d-SIN", country: "SG")

    assert_selector ".logs__line", count: 3
    assert_equal [ "web-1", "web-2", "web-1" ], all(".logs__source").map(&:text)
    assert_selector ".json-level--ok", text: "200"
    assert_selector ".json-level--bad", text: "502"
    assert_selector ".logs__text", text: /GET\s+shop\.example\.com\/cart\s+30\.0 s\s+→\s+shop-web-production-1a2b3c4d5e6f\s+from\s+203\.0\.113\.7 DE via FRA/
    assert_no_text "/admin"

    %w[ light dark ].each do |scheme|
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme } ])
      page.save_screenshot(Rails.root.join("tmp/traffic-#{scheme}.png").to_s)
    end
  end

  private
    def relay(index, *lines)
      proxy = @proxies[index]
      LiveTraffic.relay(proxy.server, proxy, { "container" => proxy.container_id, "lines" => lines })
    end

    def request(time, path, status, duration, target, service: "shop-web-production", ray: nil, country: nil)
      entry = { time: "2026-11-26T#{time}Z", level: "INFO", msg: "Request", host: "shop.example.com", port: 80, path: path, request_id: SecureRandom.hex(4),
                status: status, service: service, target: "#{target}:3000", duration: duration, method: "GET", remote_addr: "172.18.0.9",
                user_agent: "Mozilla/5.0", req_cf_connecting_ip: ("203.0.113.7" if ray), req_cf_ipcountry: country, req_cf_ray: ray }.compact
      { "t" => "2026-11-26T#{time.include?(".") ? time : "#{time}.000"}Z", "s" => "out", "m" => entry.to_json }
    end
end
