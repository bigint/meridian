# Parses a small Kamal config through KamalConfig, run inside the built image
# by CI: bin/rails runner script/smoke_parse.rb. Production loads less than
# development (v0.1.1 shipped without `require "open3"`, so every sync failed
# with a NameError that no development run could show).
config = <<~YAML
  service: web
  image: acme/web
  servers:
    - web-1.example.com
  registry:
    server: ghcr.io
    username: acme
    password:
      - KAMAL_REGISTRY_PASSWORD
  builder:
    arch: amd64
YAML

result = KamalConfig.parse({ "config/deploy.yml" => config }, [ { "path" => "config/deploy.yml", "destination" => nil } ]).first
abort "KamalConfig failed: #{result["error"].inspect}" if result.nil? || result.key?("error")
puts "Parsed config/deploy.yml with Kamal #{KamalConfig::KAMAL_VERSION}"
