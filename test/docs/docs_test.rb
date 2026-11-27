require "test_helper"
require Rails.root.join("script/docs_changelog").to_s

# Keeps the docs site in step with the code: every page is in the navigation,
# every environment variable the code reads is documented, and CHANGELOG.md
# renders as the Changelog page.
class DocsTest < ActiveSupport::TestCase
  DOCS = Rails.root.join("docs")
  ENVIRONMENT_PAGE = DOCS.join("reference/environment.mdx")

  # ENV["NAME"], ENV.fetch("NAME") and ENV.key?("NAME"), in Ruby, YAML and ERB.
  RAILS_ENV_READ = /\bENV(?:\[\s*|\.(?:fetch|key\?)\(\s*)["']([A-Z][A-Z0-9_]*)["']/
  # GitHost::GitHub reads its App settings through setting(:name, "NAME").
  GITHUB_SETTING = /\bsetting\(:\w+, "([A-Z][A-Z0-9_]*)"\)/
  # The agent reads its config through the getenv it is handed (os.Getenv).
  AGENT_ENV_READ = /\b(?:os\.Getenv|os\.LookupEnv|getenv)\("([A-Z][A-Z0-9_]*)"\)/

  # Read by the framework's own boot and test setup, not settings to document.
  UNDOCUMENTED = {
    "BUNDLE_GEMFILE" => "config/boot.rb points Bundler at the Gemfile",
    "CI" => "config/environments/test.rb eager-loads on CI services",
    "MERIDIAN_VERSION" => "the Docker build bakes in the release it came from; nobody sets it by hand"
  }.freeze

  # bin/docs writes the Changelog page from CHANGELOG.md; it isn't committed.
  GENERATED = %w[ changelog ].freeze

  test "every page in docs.json has a file, and every page file is in docs.json" do
    listed = navigation_pages(JSON.parse(DOCS.join("docs.json").read))
    files = Dir.glob("**/*.mdx", base: DOCS).reject { it.start_with?("snippets/") }.map { it.delete_suffix(".mdx") }.to_set | GENERATED

    assert_empty listed - files, "docs.json lists pages with no .mdx file"
    assert_empty files - listed, "These .mdx files aren't in docs.json's navigation"
  end

  test "every environment variable the app and the agent read is on the Environment page" do
    page = ENVIRONMENT_PAGE.read
    missing = environment_names.reject { page.match?(/\b#{it}\b/) }

    assert_empty missing, "Document these in docs/reference/environment.mdx (or add them to UNDOCUMENTED with a reason)"
  end

  test "CHANGELOG.md renders as one Update per release" do
    changelog = Rails.root.join("CHANGELOG.md").read(encoding: "UTF-8")
    releases = changelog.scan(/^## (.+)$/).flatten

    assert_equal releases.size, DocsChangelog.render(changelog).scan("<Update ").size
  end

  test "the Changelog page escapes what MDX would read as code, outside code spans" do
    mdx = DocsChangelog.render(<<~MARKDOWN)
      # Changelog

      ## v1.2.0 (2027-01-05)

      ### Fixed

      - Hosts such as `web-9<%= x %>` and {braces} or a <b> tag stay text. See <https://example.com>, [a tunnel](docs/cloudflare-tunnel.md#traffic-behind-a-tunnel), [traffic](docs/agent.md#traffic) and [the README](README.md).

      ```yaml
      env: { secret: [ <%= key %> ] }
      ```
    MARKDOWN

    assert_includes mdx, %(<Update label="v1.2.0" description="2027-01-05">)
    assert_includes mdx, "**Fixed**"
    assert_includes mdx, "`web-9<%= x %>` and \\{braces\\} or a \\<b> tag"
    assert_includes mdx, "[https://example.com](https://example.com)"
    assert_includes mdx, "[a tunnel](/guides/cloudflare-tunnel#traffic-behind-a-tunnel)"
    assert_includes mdx, "[traffic](/guides/traffic)"
    assert_includes mdx, "[the README](https://github.com/bigint/meridian/blob/main/README.md)"
    assert_includes mdx, "env: { secret: [ <%= key %> ] }"
  end

  private
    def navigation_pages(node, pages = Set.new)
      case node
      when Hash
        Array(node["pages"]).each { it.is_a?(String) ? pages << it : navigation_pages(it, pages) }
        node.except("pages").each_value { navigation_pages(it, pages) }
      when Array then node.each { navigation_pages(it, pages) }
      end
      pages
    end

    def environment_names
      rails = Dir.glob("{app,config,lib,bin,db}/**/*", base: Rails.root).flat_map do |path|
        file = Rails.root.join(path)
        next [] unless file.file?

        code = file.binread.force_encoding("UTF-8").scrub.lines.grep_v(/\A\s*#/).join
        code.scan(RAILS_ENV_READ).flatten + code.scan(GITHUB_SETTING).flatten
      end
      agent = Dir.glob(Rails.root.join("agent/*.go")).grep_v(/_test\.go\z/).flat_map { File.read(it).scan(AGENT_ENV_READ).flatten }

      (rails + agent).uniq.sort - UNDOCUMENTED.keys
    end
end
