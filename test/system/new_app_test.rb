require "application_system_test_case"

# M3: a Next.js SSR app goes from form to live through one merged PR.
class NewAppTest < ApplicationSystemTestCase
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    @project.sync
  end

  test "form, pull request, merge, deploy, live" do
    stub_request(:post, "https://api.github.com/repos/example/infra/git/refs").to_return_json(status: 201, body: { ref: "refs/heads/x" })
    writes = stub_github_writes(@project)
    stub_request(:post, "https://api.github.com/repos/example/infra/pulls").to_return_json(status: 201, body: { number: 12, html_url: "https://github.com/example/infra/pull/12" })

    sign_in users(:admin)
    visit new_app_path
    fill_in "Name", with: "shop"
    fill_in "Source repository", with: "example/shop"
    choose "Node"
    fill_in "Hostname", with: "shop.example.org"
    select "web-1.example.com", from: "Servers"
    fill_in "First version", with: "v1"
    click_on "Open pull request"

    assert_text "shop is ready for review"
    assert_link "Open pull request #12", href: "https://github.com/example/infra/pull/12"
    assert_text "Point DNS for shop.example.org"
    assert_equal %w[ deploy/shop.yml deploy/shop.version ], writes.map { it["path"] }

    # The pull request is merged: main now holds the generated files.
    merged = writes.to_h { [ it["path"], it["content"] ] }
    stub_github_repo(@project, head: "m" * 40, files: merged, history: { "deploy/shop.version" => [ [ "m" * 40, "v1\n" ] ] })
    perform_enqueued_jobs do
      deliver "push", ref: "refs/heads/main"
      deliver "workflow_run", workflow_run: { id: 8, path: ".github/workflows/meridian-deploy.yml", head_sha: "m" * 40, head_branch: "main", status: "completed", conclusion: "success", html_url: "https://github.com/example/infra/actions/runs/8", updated_at: Time.current.iso8601 }
    end

    shop = @project.apps.find_by!(service: "shop")
    assert_equal [ "node", "example/shop" ], [ shop.kind, shop.source_repo ]

    payload = { "machine_id" => "m-web-1", "hostname" => "web-1", "labels" => {},
      "containers" => [ { "id" => "s1", "name" => "shop-web-v1", "service" => "shop", "role" => "web", "destination" => "", "version" => "v1", "kind" => "app", "state" => "running", "health" => "healthy" } ] }
    Snapshot.new(payload, token: agent_tokens(:web_1)).ingest

    visit root_path(app: "shop")
    within("tr", text: "shop") { assert_selector "[data-state=in_sync]", count: 1 }
  end

  private
    def deliver(event, payload)
      body = payload.merge(repository: { full_name: @project.repo_full_name }).to_json
      signature = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", ENV["GITHUB_APP_WEBHOOK_SECRET"], body)
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post "/webhooks/github", params: body, headers: { "X-GitHub-Event" => event, "X-Hub-Signature-256" => signature, "Content-Type" => "application/json" }
    end
end
