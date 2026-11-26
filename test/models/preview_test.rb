require "test_helper"

class PreviewTest < ActiveSupport::TestCase
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    @project.sync
    @app = @project.apps.find_by!(service: "api")
    @app.update!(source_repo: "example/api-src")
    @writes = stub_github_writes(@project)
    @dispatches = []
    stub_request(:post, %r{/actions/workflows/meridian-deploy.yml/dispatches}).to_return { |r| @dispatches << JSON.parse(r.body); { status: 204 } }
    @deletes = stub_request(:delete, %r{/contents/deploy/api.pr-7.yml}).to_return_json(body: { commit: { sha: "d" * 40 } })
  end

  test "opening commits a Kamal-valid overlay next to the config and asks CI to deploy the head" do
    preview = Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: "https://github.com/example/api-src/pull/7")

    assert_equal [ "pr-7", "pr-7.api.preview.example.com", "deploy/api.pr-7.yml", "deploying" ], [ preview.destination, preview.hostname, preview.overlay_path, preview.state ]
    overlay = YAML.safe_load(@writes.sole["content"])
    assert_equal "api-pr-7", overlay["service"]
    assert_equal({ "host" => "pr-7.api.preview.example.com" }, overlay["proxy"])
    assert_equal 1, overlay.dig("servers", "web").size
    assert_equal({ "config" => "deploy/api.yml", "destination" => "pr-7", "version" => "h" * 40, "command" => "deploy" }, @dispatches.sole["inputs"])
    assert_in_delta 7.days.from_now, preview.expires_at, 1.minute
  end

  test "flat hostnames sit one level below the preview domain" do
    accounts(:main).update!(preview_hostnames: "flat")
    preview = Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil)

    assert_equal "pr-7-api.preview.example.com", preview.hostname
    assert_equal({ "host" => "pr-7-api.preview.example.com" }, YAML.safe_load(@writes.sole["content"])["proxy"])
  end

  test "a preview of a destination keeps that destination's settings" do
    web = @project.apps.find_by!(service: "web", destination: "production")
    web.update!(source_repo: "example/shop")
    Preview.deploy(web, number: 9, head_sha: "h" * 40, url: nil)

    overlay = YAML.safe_load(@writes.sole["content"])
    assert_equal "web-pr-9", overlay["service"]
    assert_equal({ "hosts" => [ "pr-9.web.preview.example.com" ], "app_port" => 3000 }, overlay["proxy"])
    assert_equal %w[ job web ], overlay["servers"].keys.sort
    assert_equal 1, overlay["servers"].values.flatten.uniq.size
    assert_match(/\A# Preview of example\/shop#9/, @writes.sole["content"])
  end

  test "pushes redeploy without rewriting the overlay" do
    Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil)
    Preview.deploy(@app, number: 7, head_sha: "i" * 40, url: nil)

    assert_equal 1, @writes.size
    assert_equal "i" * 40, @dispatches.last.dig("inputs", "version")
  end

  test "CI runs move previews along, and removal drops the overlay" do
    preview = Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil)

    Preview.track("display_title" => "deploy deploy/api.yml pr-7", "status" => "completed", "conclusion" => "success")
    assert preview.reload.active?

    preview.close
    assert preview.reload.removing?
    assert_equal "remove", @dispatches.last.dig("inputs", "command")

    stub_github_files(@project, { "deploy/api.yml" => file_fixture("infra/deploy/api.yml").read, "deploy/api.pr-7.yml" => @writes.sole["content"] }, head: "z" * 40)
    Preview.track("display_title" => "remove deploy/api.yml pr-7", "status" => "completed", "conclusion" => "success")
    assert preview.reload.removed?
    assert_requested @deletes
  end

  test "a remove run that ends after the pull request reopened leaves the new preview alone" do
    preview = Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil)
    preview.close
    Preview.deploy(@app, number: 7, head_sha: "i" * 40, url: nil)

    stub_overlay
    Preview.track("display_title" => "remove deploy/api.yml pr-7", "status" => "completed", "conclusion" => "success")
    assert preview.reload.deploying?
    assert_not_requested @deletes
  end

  test "expired previews are closed by the hourly job" do
    preview = Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil)
    travel 8.days do
      PreviewExpiryJob.perform_now
    end
    assert preview.reload.removing?
  end

  test "never picks a server whose hostname isn't a host name, nor runs its ERB" do
    accounts(:main).update!(preview_selector: "role=preview")
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "ran")
      Server.create!(name: "evil", hostname: "evil<%= File::write(#{marker.inspect}, 1) %>", labels: { "role" => "preview" })

      assert_raises(ArgumentError) { Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil) }
      assert_empty @writes
      assert_not File.exist?(marker), "ERB in a server's hostname ran"
    end
  end

  test "no preview domain, no preview" do
    accounts(:main).update!(preview_domain: nil)
    assert_raises(ArgumentError) { Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil) }
  end

  private
    def stub_overlay
      stub_github_files(@project, { "deploy/api.yml" => file_fixture("infra/deploy/api.yml").read, "deploy/api.pr-7.yml" => @writes.last["content"] }, head: "z" * 40)
    end
end

class PreviewPollingTest < ActiveSupport::TestCase
  include MemoryCacheHelper

  test "polling again over a finished remove run doesn't remove the preview that came back" do
    project = projects(:infra)
    stub_github_repo(project)
    project.sync
    app = project.apps.find_by!(service: "api")
    app.update!(source_repo: "example/api-src")
    writes = stub_github_writes(project)
    stub_request(:post, %r{/actions/workflows/meridian-deploy.yml/dispatches}).to_return(status: 204)
    deletes = stub_request(:delete, %r{/contents/deploy/api.pr-7.yml}).to_return_json(body: { commit: { sha: "d" * 40 } })

    preview = Preview.deploy(app, number: 7, head_sha: "h" * 40, url: nil)
    preview.close
    removal = { "id" => 1, "event" => "workflow_dispatch", "path" => ".github/workflows/meridian-deploy.yml", "head_branch" => "main", "head_sha" => "a" * 40,
                "status" => "completed", "conclusion" => "success", "display_title" => "remove deploy/api.yml pr-7", "updated_at" => 1.hour.ago.iso8601,
                "repository" => { "full_name" => "example/infra" } }
    stub_github_runs(project, [ removal ])
    project.poll_workflow_runs
    assert preview.reload.removed?

    Preview.deploy(app, number: 7, head_sha: "j" * 40, url: nil)
    stub_github_files(project, { "deploy/api.yml" => file_fixture("infra/deploy/api.yml").read, "deploy/api.pr-7.yml" => writes.last["content"] }, head: "z" * 40)
    stub_github_runs(project, [ removal.merge("id" => 2, "status" => "queued", "conclusion" => nil, "display_title" => "deploy deploy/api.yml pr-7", "updated_at" => Time.current.iso8601), removal ])
    project.poll_workflow_runs

    assert preview.reload.deploying?
    assert_requested deletes, times: 0
  end
end
