require "test_helper"
require "open3"

class WorkflowTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    sign_in_as users(:admin)
  end

  test "adding the CI workflow opens a pull request" do
    ref = stub_request(:post, "https://api.github.com/repos/example/infra/git/refs").to_return_json(status: 201, body: { ref: "refs/heads/x" })
    writes = stub_github_writes(@project)
    pull = stub_request(:post, "https://api.github.com/repos/example/infra/pulls").to_return_json(status: 201, body: { number: 5, html_url: "https://github.com/example/infra/pull/5" })

    post project_workflow_path(@project)

    assert_redirected_to project_path(@project)
    assert_requested ref
    assert_requested pull
    write = writes.sole
    assert_equal ".github/workflows/meridian-deploy.yml", write["path"]
    assert_match %r{\Ameridian/ci-}, write["branch"]
    assert_match "kamal deploy", write["content"]
    assert_match "gem install kamal -v 2.12.0", write["content"]
  end

  test "projects that allow direct commits get a commit instead" do
    @project.update!(direct_commits: true)
    writes = stub_github_writes(@project)

    post project_workflow_path(@project)
    assert_equal "main", writes.sole["branch"]
  end

  test "a push deploys each changed version file with its config and destination" do
    matrix = plan_push({ "deploy/web.production.version" => "v43\n", "deploy/blog.version" => "b7\n" })

    assert_equal [ [ "deploy/blog.yml", "", "b7" ], [ "deploy/web.yml", "production", "v43" ] ],
      matrix.map { it.values_at("config", "destination", "version") }.sort
  end

  test "configs ending in .yaml are found, with or without a destination" do
    matrix = plan_push({ "deploy/shop.yaml" => "service: shop\n", "deploy/shop.eu.yml" => "servers: []\n" },
      { "deploy/shop.eu.version" => "s2\n" }, { "deploy/shop.version" => "s1\n" })

    assert_equal [ [ "deploy/shop.yaml", "", "s1" ], [ "deploy/shop.yaml", "eu", "s2" ] ],
      matrix.map { it.values_at("config", "destination", "version") }.sort
  end

  test "a push of several commits deploys the version files every one of them changed" do
    matrix = plan_push({ "deploy/web.production.version" => "v43\n" }, { "deploy/blog.version" => "b7\n" })

    assert_equal %w[ deploy/blog.yml deploy/web.yml ], matrix.map { it["config"] }.sort
  end

  test "viewers can't deploy" do
    sign_in_as users(:viewer)
    @project.sync
    app = @project.apps.first

    post app_deploys_path(app), params: { deploy: { version: "v9" } }
    assert_redirected_to root_path
    assert_not_requested :put, %r{/contents/}
  end

  private
    # Runs the workflow's plan step for a push of one commit per hash of
    # files, on top of the fixture infra repository, and returns its matrix.
    def plan_push(*commits)
      skip "needs git and jq" unless system("which git jq > /dev/null 2>&1")
      step = YAML.safe_load(@project.workflow_template).dig("jobs", "plan", "steps").find { it["id"] == "plan" }

      Dir.mktmpdir do |dir|
        git = ->(*args) { Open3.capture2e("git", "-c", "user.email=ci@example.com", "-c", "user.name=CI", *args, chdir: dir).first.strip }
        FileUtils.cp_r("#{GitHubHelper::INFRA}/.", dir)
        git.("init", "-q")
        git.("add", "--all")
        git.("commit", "-qm", "init")
        before = git.("rev-parse", "HEAD")

        commits.each_with_index do |files, index|
          files.each { |path, content| File.write(File.join(dir, path), content) }
          git.("add", "--all")
          git.("commit", "-qm", "change #{index}")
        end

        script = step["run"].gsub("${{ github.event_name }}", "push").gsub("${{ github.event.before }}", before).gsub(/\$\{\{[^}]*\}\}/, "")
        output, status = Open3.capture2e({ "GITHUB_OUTPUT" => File.join(dir, ".output") }, "bash", "-c", script, chdir: dir)
        assert status.success?, output
        JSON.parse(File.read(File.join(dir, ".output"))[/^matrix=(.*)$/, 1])
      end
    end
end
