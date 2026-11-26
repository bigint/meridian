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

    track("deploy deploy/api.yml pr-7")
    assert preview.reload.active?

    preview.close
    assert preview.reload.removing?
    assert_equal "remove", @dispatches.last.dig("inputs", "command")

    stub_github_files(@project, { "deploy/api.yml" => file_fixture("infra/deploy/api.yml").read, "deploy/api.pr-7.yml" => @writes.sole["content"] }, head: "z" * 40)
    track("remove deploy/api.yml pr-7")
    assert preview.reload.removed?
    assert_requested @deletes
  end

  test "a remove run that ends after the pull request reopened leaves the new preview alone" do
    preview = Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil)
    preview.close
    Preview.deploy(@app, number: 7, head_sha: "i" * 40, url: nil)

    stub_overlay
    track("remove deploy/api.yml pr-7")
    assert preview.reload.deploying?
    assert_not_requested @deletes
  end

  test "a deploy run GitHub cancelled for a newer one leaves the preview to that one" do
    preview = Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil)
    Preview.deploy(@app, number: 7, head_sha: "i" * 40, url: nil)
    Preview.deploy(@app, number: 7, head_sha: "k" * 40, url: nil)

    track("deploy deploy/api.yml pr-7", conclusion: "cancelled")
    assert preview.reload.deploying?
    track("deploy deploy/api.yml pr-7", conclusion: "failure")
    track("deploy deploy/api.yml pr-7")
    assert preview.reload.active?
  end

  test "a failed removal can be tried again, and keeps its overlay" do
    preview = Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil)
    preview.close
    track("remove deploy/api.yml pr-7", conclusion: "failure")
    assert preview.reload.failed?

    assert_not_requested @deletes

    preview.close
    assert preview.reload.removing?
    assert_equal 2, @dispatches.count { it.dig("inputs", "command") == "remove" }
  end

  test "an overlay GitHub won't delete keeps its preview in removing" do
    preview = Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil)
    preview.close
    stub_overlay
    stub_request(:delete, %r{/contents/deploy/api.pr-7.yml}).to_return(status: 502, body: "{}", headers: { "Content-Type" => "application/json" })

    assert_raises(GitHost::Error) { track("remove deploy/api.yml pr-7") }
    assert preview.reload.removing?
  end

  test "a project GitHub refuses doesn't stop other previews expiring" do
    other = Project.create!(name: "Other", repo_full_name: "example/other", installation_id: 2, config_globs: [ "deploy/*.yml" ])
    stub_installation_token(other)
    stub_request(:post, %r{/repos/example/other/actions/workflows/meridian-deploy.yml/dispatches}).to_return(status: 403, body: "{}", headers: { "Content-Type" => "application/json" })
    stuck = other.apps.create!(service: "x", config_path: "deploy/x.yml", source_repo: "example/x-src")
      .previews.create!(pr_number: 1, destination: "pr-1", hostname: "pr-1.x.preview.example.com", overlay_path: "deploy/x.pr-1.yml", expires_at: 1.day.ago)
    preview = Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil)

    travel(8.days) { PreviewExpiryJob.perform_now }
    assert_equal [ "deploying", "removing" ], [ stuck.reload.state, preview.reload.state ]
  end

  test "CI removes only the preview's app, never the accessories it shares" do
    script = YAML.safe_load(@project.workflow_template).dig("jobs", "kamal", "steps").find { it["name"] == "Kamal" }["run"]

    assert_match(/^\s*kamal app remove "\$\{args\[@\]\}"$/, script)
    assert_no_match(/^\s*kamal remove/, script)
    assert_match "format('{0} {1} {2}', inputs.command, inputs.config, inputs.destination)", @project.workflow_template, "remove runs are still named remove <config> pr-<n>"
  end

  test "a deploy GitHub has no workflow for fails instead of waiting for ever" do
    stub_request(:post, %r{/actions/workflows/meridian-deploy.yml/dispatches}).to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })

    error = assert_raises(GitHost::NotFound) { Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil) }
    assert_match "no meridian-deploy.yml workflow on main", error.message
    assert @app.previews.sole.failed?
  end

  test "a selector with stray spaces still finds the preview server" do
    Server.find_by!(hostname: "web-2.example.com").update!(labels: { "role" => "preview" })
    accounts(:main).update!(preview_selector: " role=preview,")

    Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil)
    assert_equal [ "web-2.example.com" ], YAML.safe_load(@writes.sole["content"]).dig("servers", "web")
  end

  test "a malformed selector saved earlier matches no server rather than crashing" do
    accounts(:main).update_column(:preview_selector, "preview")

    error = assert_raises(ArgumentError) { Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil) }
    assert_equal "No server matches the preview selector", error.message
  end

  test "a run is matched to a preview in its own repository only" do
    other = Project.create!(name: "Other", repo_full_name: "example/other", installation_id: 2, config_globs: [ "deploy/*.yml" ])
    theirs = other.apps.create!(service: "api", config_path: "deploy/api.yml", source_repo: "example/other-src")
      .previews.create!(pr_number: 7, destination: "pr-7", hostname: "pr-7.api.example.org", overlay_path: "deploy/api.pr-7.yml", state: "removing", expires_at: 1.day.from_now)
    mine = Preview.deploy(@app, number: 7, head_sha: "h" * 40, url: nil)
    mine.close

    track("remove deploy/api.yml pr-7")
    assert_equal [ "removed", "removing" ], [ mine.reload.state, theirs.reload.state ]
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
    def track(title, conclusion: "success", repository: "example/infra")
      Preview.track("display_title" => title, "status" => "completed", "conclusion" => conclusion, "repository" => { "full_name" => repository })
    end

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
