require "test_helper"

class ProjectSyncTest < ActiveSupport::TestCase
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
  end

  test "classifies destination files by their base config" do
    paths = %w[ deploy/web.yml deploy/web.staging.yml deploy/web.production.yml deploy/web.eu.yml deploy/blog.yml README.md other/x.yml ]

    assert_equal({ "deploy/blog.yml" => [ nil ], "deploy/web.yml" => %w[ eu production staging ] }, @project.config_paths(paths))
  end

  test "a destination file ends in .yml, as Kamal looks for, whatever the base ends in" do
    @project.config_globs = [ "deploy/*" ]
    paths = %w[ deploy/web.yml deploy/web.staging.yaml deploy/api.yaml deploy/api.eu.yml ]

    assert_equal({ "deploy/api.yaml" => [ "eu" ], "deploy/web.staging.yaml" => [ nil ], "deploy/web.yml" => [ nil ] }, @project.config_paths(paths))
  end

  test "a .yaml file beside a .yml config is read as a config of its own" do
    @project.update!(config_globs: [ "deploy/*" ])
    files = infra_files.except("deploy/web.staging.yml").merge("deploy/web.staging.yaml" => infra_files["deploy/web.staging.yml"])
    stub_github_files(@project, files, head: "1" * 40)

    assert @project.sync
    assert_includes @project.reload.config_errors.map { it["file"] }, "deploy/web.staging.yaml"
  end

  test "sync records every app, server and assignment Git describes" do
    assert @project.sync

    assert_equal [ "api", "blog", "web · production", "web · staging" ], @project.apps.ordered.map(&:name)

    web = @project.apps.find_by!(service: "web", destination: "production")
    assert_equal [ "shop.example.com" ], web.hostnames
    assert_equal %w[ jobs-1.example.com web-1.example.com web-2.example.com ], web.servers.map(&:name).sort
    assert_equal %w[ job web web ], web.assignments.map(&:role).sort

    assert_equal 1, Server.where(name: "web-1.example.com").count, "a server shared by apps appears once"
    assert_equal %w[ API_TOKEN_PRODUCTION DATABASE_URL KAMAL_REGISTRY_PASSWORD ], @project.apps.find_by!(service: "api").secret_names
    assert_equal "a" * 40, @project.reload.last_synced_sha
  end

  test "sync records each accessory's image, so a tunnel is found by what it runs" do
    @project.sync

    db = @project.apps.find_by!(service: "api").accessories.sole
    assert_equal "postgres:17", db["image"]
    assert_equal "db-1.example.com", db["hosts"].sole
    assert_equal [], db["secrets"]
  end

  test "secret names include those set per server tag" do
    files = { "deploy/tagged.yml" => <<~YAML }
      service: tagged
      image: example/tagged
      servers:
        web:
          hosts:
            - web-1.example.com: singapore
      env:
        secret: [ DATABASE_URL ]
        tags:
          singapore:
            secret: [ "DATABASE_REPLICA_URL:SINGAPORE_REPLICA_URL" ]
      registry: { server: ghcr.io, username: example, password: [ KAMAL_REGISTRY_PASSWORD ] }
      builder: { arch: amd64 }
    YAML
    stub_github_files(@project, files, head: "f" * 40)

    @project.sync
    assert_equal %w[ DATABASE_URL KAMAL_REGISTRY_PASSWORD SINGAPORE_REPLICA_URL ], @project.apps.sole.secret_names
  end

  test "a secret name GitHub can't store is left out, and the rest of the sync goes on" do
    files = infra_files.merge("deploy/ghcr.yml" => <<~YAML)
      service: ghcr
      image: example/ghcr
      servers: [ web-9.example.com ]
      env: { secret: [ GITHUB_TOKEN, SMTP_PASSWORD ] }
      registry: { server: ghcr.io, username: example, password: [ KAMAL_REGISTRY_PASSWORD ] }
      builder: { arch: amd64 }
    YAML
    stub_github_files(@project, files, head: "f" * 40)

    assert @project.sync
    assert @project.apps.exists?(service: "ghcr")
    assert_equal [ "ghcr" ], @project.secret_names.find_by!(name: "SMTP_PASSWORD").apps
    assert_not @project.secret_names.exists?(name: "GITHUB_TOKEN")
  end

  test "a second sync in the same job records the secret names of what it just synced" do
    @project.sync
    files = infra_files.merge("deploy/api.yml" => infra_files["deploy/api.yml"].sub("    - DATABASE_URL\n", "    - DATABASE_URL\n    - NEW_SECRET\n"))
    stub_github_files(@project, files, head: "b" * 40)
    stub_github_runs(@project, [ { id: 1, path: ".github/workflows/meridian-deploy.yml", head_sha: "b" * 40, head_branch: "main", event: "push", status: "queued", display_title: "x", html_url: "u", updated_at: Time.current.iso8601 } ])

    @project.poll_workflow_runs
    assert_equal "b" * 40, @project.reload.last_synced_sha
    assert_equal [ "api" ], @project.secret_names.find_by!(name: "NEW_SECRET").apps
  end

  test "a config that prints doesn't spoil the parser's answer" do
    files = infra_files.merge("deploy/chatty.yml" => <<~YAML)
      <% puts "rendering chatty"; system("echo", "from a command") %>
      service: chatty
      image: example/chatty
      servers: [ web-9.example.com ]
      registry: { server: ghcr.io, username: example, password: [ KAMAL_REGISTRY_PASSWORD ] }
      builder: { arch: amd64 }
    YAML
    stub_github_files(@project, files, head: "6" * 40)

    assert @project.sync
    assert @project.apps.exists?(service: "chatty")
    assert_equal "6" * 40, @project.reload.last_synced_sha
  end

  test "a config that kills the parser keeps every app and says why" do
    @project.sync
    files = infra_files.merge("deploy/gone.yml" => "<% exit!(0) %>\nservice: gone\n")
    stub_github_files(@project, files, head: "5" * 40)

    assert @project.sync
    assert_equal 4, @project.apps.count
    assert_equal "The parser exited without a result", @project.reload.config_errors.sole["message"]
  end

  test "a head the parser failed on is tried again, with backoff, until it parses" do
    @project.sync
    stub_github_files(@project, infra_files.merge("deploy/gone.yml" => "<% exit!(0) %>\nservice: gone\n"), head: "5" * 40)
    assert @project.sync
    assert_equal "a" * 40, @project.reload.last_synced_sha, "a parser that may only have timed out doesn't mark the head synced"

    assert_not @project.sync, "not again at once"
    travel 61.seconds
    assert @project.sync, "again after a minute"
    travel 61.seconds
    assert_not @project.sync, "then after two"
    assert_equal 2, @project.reload.parse_failures
    assert_equal "The parser exited without a result", @project.config_errors.sole["message"]

    stub_github_files(@project, infra_files.merge("deploy/gone.yml" => "service: gone\nimage: example/gone\nservers: [ web-1.example.com ]\nregistry: { username: x, password: [ KAMAL_REGISTRY_PASSWORD ] }\nbuilder: { arch: amd64 }\n"), head: "5" * 40)
    travel 2.minutes
    assert @project.sync
    assert_equal [ "5" * 40, 0 ], [ @project.reload.last_synced_sha, @project.parse_failures ]
    assert @project.apps.exists?(service: "gone")
  end

  test "a meridian label taken out of the config is cleared" do
    config = <<~YAML
      service: shop
      image: example/shop
      servers: [ web-9.example.com ]
      labels: { meridian.kind: node, meridian.source: acme/shop }
      registry: { server: ghcr.io, username: example, password: [ KAMAL_REGISTRY_PASSWORD ] }
      builder: { arch: amd64 }
    YAML
    stub_github_files(@project, { "deploy/shop.yml" => config }, head: "4" * 40)
    @project.sync
    assert_equal [ "node", "acme/shop" ], @project.apps.sole.values_at(:kind, :source_repo)

    stub_github_files(@project, { "deploy/shop.yml" => config.sub(/^labels:.*\n/, "") }, head: "3" * 40)
    @project.sync
    assert_equal [ "other", nil ], @project.apps.sole.values_at(:kind, :source_repo)
  end

  test "parse errors carry file and line" do
    @project.sync

    error = @project.reload.config_errors.sole
    assert_equal "deploy/broken.yml", error["file"]
    assert_equal 6, error["line"]
    assert_match "servers/web/hosts: should be an array", error["message"]
  end

  test "a YAML syntax error in a destination file names that file" do
    files = infra_files.merge("deploy/web.staging.yml" => "servers:\n  web:\n    - staging-1.example.com\nproxy: [unclosed\n")
    stub_github_files(@project, files, head: "2" * 40)
    @project.sync

    error = @project.reload.config_errors.find { it["class"] == "Psych::SyntaxError" }
    assert_equal [ "deploy/web.staging.yml", 4 ], error.values_at("file", "line")
  end

  test "releases come from the version file when there is one" do
    stub_github_repo(@project, history: { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ], [ "b" * 40, "v41\n" ] ] })
    @project.sync

    web = @project.apps.find_by!(service: "web", destination: "production")
    assert web.versioned?
    assert_equal %w[ v42 v41 ], web.releases.map(&:version)

    blog = @project.apps.find_by!(service: "blog")
    assert_not blog.versioned?
    assert_equal 7, blog.latest_release.version.length
  end

  test "the newest release is the one that landed last, not the one written last" do
    stub_github_repo(@project, history: { "deploy/web.production.version" => [ [ "c" * 40, "v43\n" ], [ "b" * 40, "v42\n" ] ] })
    # v43 was written on a branch yesterday and rebased onto main after v42.
    stub_request(:get, %r{/repos/example/infra/commits\?}).with(query: hash_including("path" => "deploy/web.production.version")).to_return_json(body: [
      { sha: "c" * 40, commit: { message: "deploy: v43", author: { name: "Ada", date: 1.day.ago.iso8601 }, committer: { name: "GitHub", date: 1.minute.ago.iso8601 } } },
      { sha: "b" * 40, commit: { message: "deploy: v42", author: { name: "Bob", date: 1.hour.ago.iso8601 }, committer: { name: "Bob", date: 1.hour.ago.iso8601 } } }
    ])
    @project.sync

    web = @project.apps.find_by!(service: "web", destination: "production")
    assert_equal "v43", web.latest_release.version
    assert_equal [ [ web.id, "v43" ] ], Release.latest_per_app.where(app: web).pluck(:app_id, :version)
  end

  test "an unchanged head is not synced again" do
    @project.sync
    assert_not @project.sync
    assert @project.sync(force: true)
  end

  test "apps removed from Git are removed" do
    @project.sync
    files = Dir.glob("**/*", File::FNM_DOTMATCH, base: GitHubHelper::INFRA).select { File.file?(GitHubHelper::INFRA.join(it)) }.reject { it == "deploy/blog.yml" }
    stub_github_files(@project, files.index_with { File.read(GitHubHelper::INFRA.join(it)) }, head: "d" * 40)

    @project.sync
    assert_nil @project.apps.find_by(service: "blog")
  end

  test "a truncated tree stops the sync instead of reading as deleted configs" do
    @project.sync
    stub_request(:get, "#{GitHubHelper::API}/repos/example/infra/branches/main").to_return_json(body: { commit: { sha: "7" * 40 } })
    stub_request(:get, "#{GitHubHelper::API}/repos/example/infra/git/trees/#{"7" * 40}?recursive=true")
      .to_return_json(body: { sha: "7" * 40, tree: [ { path: "deploy/blog.yml", type: "blob", sha: "1" * 40 } ], truncated: true })

    assert_raises(GitHost::Error) { @project.sync }
    assert_equal 4, @project.apps.count
    assert_equal "a" * 40, @project.reload.last_synced_sha
  end

  test "ERB in configs cannot see Meridian's environment" do
    files = { "deploy/leak.yml" => <<~YAML }
      service: leak
      image: example/<%= ENV.fetch("GITHUB_APP_ID", "none") %>
      servers: [ web-9.example.com ]
      registry: { server: ghcr.io, username: example, password: [ KAMAL_REGISTRY_PASSWORD ] }
      builder: { arch: amd64 }
    YAML
    stub_github_files(@project, files, head: "e" * 40)

    @project.sync
    assert_empty @project.reload.config_errors
    assert_equal "example/none", @project.apps.sole.image
  end

  test "a config that stops parsing keeps its app, deploys and releases" do
    stub_github_repo(@project, history: { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ], [ "b" * 40, "v41\n" ] ] })
    @project.sync
    web = @project.apps.find_by!(service: "web", destination: "production")
    web.deploys.create!(version: "v42", commit_sha: "c" * 40, actor: users(:ada))

    stub_github_files(@project, infra_files.merge("deploy/web.production.yml" => "servers:\n  web:\n    hosts: web-1.example.com\n"), head: "d" * 40)
    @project.sync

    assert_includes @project.reload.config_errors.map { it["file"] }, "deploy/web.production.yml"
    assert_equal [ 1, 2 ], [ web.deploys.count, web.releases.count ]
    assert_equal %w[ jobs-1.example.com web-1.example.com web-2.example.com ], web.reload.servers.map(&:name).sort
  end

  test "releases are read from GitHub before the write transaction opens" do
    outside = ActiveRecord::Base.connection.open_transactions
    during = []
    stub_request(:get, %r{\A#{Regexp.escape(GitHubHelper::API)}/repos/example/infra/commits\?}).to_return do
      during << ActiveRecord::Base.connection.open_transactions
      { status: 200, body: "[]", headers: { "Content-Type" => "application/json" } }
    end

    @project.sync
    assert_not_empty during
    assert_equal [ outside ], during.uniq
  end

  private
    def infra_files
      Dir.glob("**/*", File::FNM_DOTMATCH, base: GitHubHelper::INFRA).select { File.file?(GitHubHelper::INFRA.join(it)) }.index_with { File.read(GitHubHelper::INFRA.join(it)) }
    end
end
