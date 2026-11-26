# A server with a container placed on it, ready for log tests.
module LogsTestHelper
  WEB = "a" * 64
  WORKER = "b" * 64

  def place(server, container_id, app: nil, name: "web-web-production-v42", **attributes)
    Placement.create!({ server: server, app: app, container_id: container_id, name: name, service: "web", role: "web", state: "running", observed_at: Time.current }.merge(attributes))
  end

  def server_named(name)
    Server.create!(name: name, hostname: name, machine_id: "m-#{name}", last_seen_at: Time.current)
  end

  def batch(container, lines: [ { "t" => "2026-11-26T12:16:25.123456789Z", "s" => "out", "m" => "GET / 200" } ], **extra)
    { "action" => "logs", "container" => container, "lines" => lines }.merge(extra.stringify_keys)
  end
end
