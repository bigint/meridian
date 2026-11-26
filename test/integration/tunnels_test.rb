require "test_helper"

class TunnelsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:viewer)
    @project = projects(:infra)
    @a, @b = %w[ a b ].map { Server.create!(name: "#{it}.example.com", hostname: "#{it}.example.com", last_seen_at: 1.second.ago) }
  end

  test "shows the shared tunnel, its connectors and which apps it can serve" do
    make_app("edge", kind: App::ACCESSORIES, accessories: %w[ a b ].map { connector(it) })
    @a.placements.create!(container_id: "c1", name: "edge-cloudflared-a", kind: "accessory", service: "edge-cloudflared-a", state: "running", observed_at: Time.current)
    make_app("shop", hostnames: [ "shop.example.com" ], on: [ @a, @b ])
    make_app("blog", hostnames: [ "blog.example.com" ], on: [ @a ])

    get tunnels_path

    assert_response :success
    assert_select ".page-header__meta", text: /1 Cloudflare Tunnel. 1 needs attention/
    assert_select ".card__header", text: /edge/
    assert_select ".badge", text: "running"
    assert_select ".badge", text: "not started"
    assert_select ".copyable code", text: "kamal accessory boot cloudflared-b -c deploy/edge.yml"
    assert_select "li", text: /shop.*shop\.example\.com/m
    assert_select ".alert", text: /Don't route blog through this tunnel yet.*b\.example\.com/m
  end

  test "spells out the setup for the picked servers, with the edge config to commit" do
    make_app("shop", hostnames: [ "shop.example.com" ], on: [ @a, @b ])
    make_app("blog", hostnames: [ "blog.example.com" ], on: [ @a ])

    get new_tunnel_path(hosts: [ "a.example.com", "b.example.com" ])

    assert_response :success
    assert_select "input[type=checkbox][name='hosts[]'][checked]", 2
    assert_select ".walk__step", 7
    assert_select ".copyable code", text: "CLOUDFLARE_TUNNEL_TOKEN=$CLOUDFLARE_TUNNEL_TOKEN"
    assert_select ".code-block__bar", text: /deploy\/edge\.yml/
    assert_select ".code-block code", text: /cloudflared-a:.*host: a\.example\.com.*cloudflared-b:.*host: b\.example\.com/m
    assert_select ".code-block code", text: "kamal accessory boot all -c deploy/edge.yml"
    assert_select ".copyable code", text: "shop.example.com"
    assert_select ".copyable code", { text: "blog.example.com", count: 0 }
    assert_select ".alert", text: /blog isn't on every one of these servers/
  end

  test "picking one server makes every app on it ready to route" do
    make_app("blog", hostnames: [ "blog.example.com" ], on: [ @a ])

    get new_tunnel_path(hosts: [ "a.example.com" ])

    assert_select ".copyable code", text: "blog.example.com"
    assert_select ".alert", count: 0
  end

  test "asks for a server instead of showing a config Kamal would reject" do
    get new_tunnel_path

    assert_response :success
    assert_select ".walk__note", text: /Pick at least one server/
    assert_select ".code-block__bar", text: /deploy\/edge\.yml/, count: 0
  end

  test "says so when there is no tunnel" do
    get tunnels_path

    assert_response :success
    assert_select ".empty__title", text: "No tunnels yet"
    assert_select ".page-header a.btn--primary[href=?]", new_tunnel_path, text: /Set up a tunnel/
  end

  test "warns about nested preview hostnames and links admins to settings" do
    Account.current.update!(preview_domain: "preview.example.com", preview_hostnames: "nested")

    get tunnels_path
    assert_select "code", text: "pr-12.shop.preview.example.com"
    assert_select ".alert", text: /two levels below the domain/
    assert_select ".alert a[href=?]", settings_account_path, count: 0

    sign_in_as users(:admin)
    get tunnels_path
    assert_select ".alert a[href=?]", settings_account_path
  end

  test "flat preview hostnames need no warning" do
    Account.current.update!(preview_domain: "preview.example.com", preview_hostnames: "flat")

    get tunnels_path
    assert_select "code", text: "pr-12-shop.preview.example.com"
    assert_select ".alert", count: 0
  end

  test "an admin edits the connectors and Meridian commits the edge config" do
    source = file_fixture("edge/generated.yml").read
    @project.update!(direct_commits: true)
    @project.apps.create!(service: "edge", kind: App::ACCESSORIES, config_path: "deploy/edge.yml",
      accessories: KamalConfig.parse({ "deploy/edge.yml" => source }, [ { "path" => "deploy/edge.yml", "destination" => nil } ]).sole["accessories"])
    stub_github_files(@project, { "deploy/edge.yml" => source })
    writes = stub_github_writes(@project)
    sign_in_as users(:admin)
    hosts = %w[ aps2-az1-node-01 apse1-az1-node-01 euc1-az1-node-01 ]

    get tunnels_path
    assert_select "a[href=?]", edit_tunnels_connectors_path(project: @project.id, secret: "CLOUDFLARE_TUNNEL_TOKEN"), text: "Edit connectors"

    get edit_tunnels_connectors_path(project: @project.id, secret: "CLOUDFLARE_TUNNEL_TOKEN", hosts: hosts)
    assert_response :success
    assert_select ".badge", text: "+ add"
    assert_select ".badge", text: "− remove"
    assert_select "button", text: /Commit the change/

    patch tunnels_connectors_path(project: @project.id, secret: "CLOUDFLARE_TUNNEL_TOKEN"), params: { hosts: hosts }
    assert_response :created
    assert_equal "deploy/edge.yml", writes.sole["path"]
    assert_includes writes.sole["content"], "  cloudflared-euc1-az1-node-01:\n"
    assert_not_includes writes.sole["content"], "aps2-az1-node-02"
    assert_select ".code-block code", text: "kamal accessory remove cloudflared-aps2-az1-node-02 -c deploy/edge.yml -y"
    assert_select ".code-block code", text: "kamal accessory boot cloudflared-euc1-az1-node-01 -c deploy/edge.yml"
  end

  test "a crafted host in the edit link is refused, and its ERB never runs" do
    source = file_fixture("edge/generated.yml").read
    @project.apps.create!(service: "edge", kind: App::ACCESSORIES, config_path: "deploy/edge.yml",
      accessories: KamalConfig.parse({ "deploy/edge.yml" => source }, [ { "path" => "deploy/edge.yml", "destination" => nil } ]).sole["accessories"])
    stub_github_files(@project, { "deploy/edge.yml" => source })
    sign_in_as users(:admin)

    Dir.mktmpdir do |dir|
      marker = File.join(dir, "ran")
      get edit_tunnels_connectors_path(project: @project.id, secret: "CLOUDFLARE_TUNNEL_TOKEN", hosts: [ "aps2-az1-node-01", "x<%= File::write(#{marker.inspect}, 1) %>" ])

      assert_response :success
      assert_select ".alert", text: /Not a server name/
      assert_select "button", text: /Commit the change|Open a pull request/, count: 0
      assert_not File.exist?(marker), "ERB from the query string ran"
    end
  end

  test "only admins edit connectors" do
    make_app("edge", kind: App::ACCESSORIES, accessories: [ connector("a") ])

    get tunnels_path
    assert_select "a", text: "Edit connectors", count: 0

    get edit_tunnels_connectors_path(project: @project.id, secret: "CLOUDFLARE_TUNNEL_TOKEN")
    assert_redirected_to root_path
    assert_equal "You don't have permission to do that.", flash[:alert]
  end

  test "the sidebar links to the page" do
    get tunnels_path
    assert_select "nav[aria-label=Manage] a[href=?]", tunnels_path, text: "Tunnels"
  end

  private
    def make_app(service, kind: "other", hostnames: [], on: [], accessories: [])
      app = @project.apps.create!(service: service, kind: kind, config_path: "deploy/#{service}.yml", hostnames: hostnames,
        accessories: accessories.map { it.merge("service" => "#{service}-#{it["name"]}") })
      on.each { app.assignments.create!(server: it, role: "web") }
      app
    end

    def connector(server)
      { "name" => "cloudflared-#{server}", "image" => "cloudflare/cloudflared:2026.11.2", "hosts" => [ "#{server}.example.com" ], "secrets" => [ "CLOUDFLARE_TUNNEL_TOKEN" ] }
    end

  test "an array where a project id belongs is not an error" do
    get tunnels_path(project: [ @project.id ])
    assert_response :success

    sign_in_as users(:admin)
    get edit_tunnels_connectors_path(project: [ @project.id ], secret: "CLOUDFLARE_TUNNEL_TOKEN")
    assert_response :not_found
  end
end
