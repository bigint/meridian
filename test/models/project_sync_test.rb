require "test_helper"

class ProjectSyncTest < ActiveSupport::TestCase
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
  end

  test "classifies destination files by their base config" do
    paths = %w[ deploy/web.yml deploy/web.staging.yml deploy/web.production.yml deploy/web.pr-12.yml deploy/blog.yml README.md other/x.yml ]

    assert_equal({ "deploy/blog.yml" => [ nil ], "deploy/web.yml" => %w[ production staging ] }, @project.config_paths(paths))
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

  test "parse errors carry file and line" do
    @project.sync

    error = @project.reload.config_errors.sole
    assert_equal "deploy/broken.yml", error["file"]
    assert_equal 6, error["line"]
    assert_match "servers/web/hosts: should be an array", error["message"]
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
end
