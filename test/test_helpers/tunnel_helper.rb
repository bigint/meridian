# Configs and connectors for the tunnel tests, in @project.
module TunnelHelper
  # A config whose web role runs behind kamal-proxy on the `on:` servers.
  # Each accessory gets the service name Kamal gives it.
  def make_app(service, kind: "other", hostnames: [], on: [], accessories: [])
    app = @project.apps.create!(service: service, kind: kind, config_path: "deploy/#{service}.yml", hostnames: hostnames,
      roles: [ { "name" => "web", "hosts" => on.map(&:hostname), "proxy" => true } ],
      accessories: accessories.map { it.merge("service" => "#{service}-#{it["name"]}") })
    on.each { app.assignments.create!(server: it, role: "web") }
    app
  end

  # A cloudflared accessory on one host, reading its token from secret.
  def connector(name, host, secret: "CLOUDFLARE_TUNNEL_TOKEN")
    { "name" => name, "image" => "cloudflare/cloudflared:2026.11.2", "hosts" => [ host ], "secrets" => [ secret ] }
  end
end
