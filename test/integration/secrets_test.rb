require "test_helper"

class SecretsTest < ActionDispatch::IntegrationTest
  SENTINEL = "s3ntinel-#{SecureRandom.hex(16)}"

  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    @project.sync
    @key = RbNaCl::PrivateKey.generate
    stub_request(:get, "https://api.github.com/repos/example/infra/actions/secrets/public-key")
      .to_return_json(body: { key_id: "k1", key: Base64.strict_encode64(@key.public_key.to_bytes) })
    @sent = []
    @put = stub_request(:put, %r{/repos/example/infra/actions/secrets/}).to_return do |request|
      @sent << [ URI(request.uri).path, JSON.parse(request.body) ]
      { status: 204 }
    end
  end

  test "names come from the configs that reference them" do
    assert_equal %w[ API_TOKEN_PRODUCTION DATABASE_URL KAMAL_REGISTRY_PASSWORD RAILS_MASTER_KEY ], @project.secret_names.order(:name).pluck(:name)
    assert_equal [ "web · production", "web · staging" ], @project.secret_names.find_by!(name: "RAILS_MASTER_KEY").apps
  end

  test "a name added by hand without a value outlives the next sync" do
    sign_in_as users(:ada)
    post secrets_path, params: { project_id: @project.id, secret_name: { name: "CERTIFICATE_PEM" } }
    assert_redirected_to secrets_path(anchor: "project-#{@project.id}")

    stub_github_repo(@project, head: "b" * 40)
    assert @project.sync
    assert_equal [], @project.secret_names.find_by!(name: "CERTIFICATE_PEM").apps
  end

  test "a name that was set and is no longer referenced says so" do
    secret = @project.secret_names.find_by!(name: "API_TOKEN_PRODUCTION")
    secret.update!(last_set_at: Time.current)
    stub_github_files(@project, infra_files(except: [ "deploy/api.yml" ]), head: "b" * 40)

    @project.sync
    assert_not secret.reload.referenced?
    assert_not @project.secret_names.exists?(name: "DATABASE_URL"), "a name nobody set goes with its last reference"
  end

  test "an empty value is turned away before anything reaches GitHub" do
    sign_in_as users(:ada)
    secret = @project.secret_names.find_by!(name: "DATABASE_URL")

    patch secret_path(secret), params: { secret_value: " " }

    assert_redirected_to secrets_path
    assert_equal "Type a value for DATABASE_URL.", flash[:alert]
    assert_not_requested @put
    assert_nil secret.reload.last_set_at
  end

  test "a secret says when it was last set through Meridian" do
    sign_in_as users(:ada)
    SecretName.create!(project: @project, name: "API_KEY", last_set_at: 1.day.ago)

    get secrets_path

    assert_select "tr", text: /API_KEY.*1 day ago/m
  end

  test "secret_names has no column that could hold a value" do
    assert_equal %w[ apps created_at id last_set_at name project_id updated_at ], SecretName.column_names.sort
  end

  test "a rotated value is sealed for GitHub and never persisted, logged, enqueued or broadcast" do
    sign_in_as users(:ada)
    secret = @project.secret_names.find_by!(name: "DATABASE_URL")
    log = capture_log do
      assert_no_enqueued_jobs do
        patch secret_path(secret), params: { secret_value: SENTINEL }
      end
    end
    assert_redirected_to secrets_path(anchor: "project-#{@project.id}")

    path, sealed = @sent.sole
    assert path.end_with?("/actions/secrets/DATABASE_URL")
    assert_equal "k1", sealed["key_id"]
    assert_equal SENTINEL, RbNaCl::Boxes::Sealed.from_private_key(@key).decrypt(Base64.decode64(sealed["encrypted_value"]))

    assert_not_includes log, SENTINEL
    assert_includes log, "[FILTERED]"
    assert_not_includes database_dump, SENTINEL
    follow_redirect!
    assert_not_includes response.body, SENTINEL
    assert secret.reload.last_set_at
    assert_equal "secret.set", Event.recent.first.action
  end

  private
    def capture_log
      io = StringIO.new
      logger = ActiveSupport::Logger.new(io)
      original = Rails.logger
      Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = logger
      yield
      io.string
    ensure
      Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = original
    end

    def database_dump
      connection = ActiveRecord::Base.connection
      connection.tables.flat_map { |table| connection.select_rows("SELECT * FROM #{connection.quote_table_name(table)}") }.flatten.join("\n")
    end
end
