# Writes docs/changelog.mdx from CHANGELOG.md: one Mintlify <Update> per
# release, newest first, so the docs site's Changelog tab says what the file
# says. CHANGELOG.md stays the one place to edit: bin/docs writes the page
# before every preview and check, and git ignores it.
#
#   ruby script/docs_changelog.rb    (or bin/docs changelog)
module DocsChangelog
  SOURCE = File.expand_path("../CHANGELOG.md", __dir__)
  TARGET = File.expand_path("../docs/changelog.mdx", __dir__)
  REPOSITORY = "https://github.com/bigint/meridian/blob/main/".freeze

  # The Markdown docs CHANGELOG.md links to, and where each lives on the site
  # now. A section that moved to a page of its own is keyed with its anchor.
  PAGES = {
    "docs/agent.md" => "/guides/agent",
    "docs/agent.md#traffic" => "/guides/traffic",
    "docs/architecture.md" => "#{REPOSITORY}contributing/architecture.md",
    "docs/cloudflare-tunnel.md" => "/guides/cloudflare-tunnel",
    "docs/configuration.md" => "/operate/settings",
    "docs/decisions.md" => "#{REPOSITORY}contributing/decisions.md",
    "docs/design.md" => "#{REPOSITORY}contributing/design.md",
    "docs/install.md" => "/install",
    "docs/litestream.md" => "/operate/backups",
    "docs/previews.md" => "/guides/previews",
    "docs/security.md" => "/operate/security"
  }.freeze

  HEADER = <<~MDX.freeze
    ---
    title: "Changelog"
    description: "What changed in each Meridian release, newest first."
    icon: "history"
    ---

    {/* Generated from CHANGELOG.md by script/docs_changelog.rb. Edit CHANGELOG.md, then run bin/docs changelog. */}

    This page is [`CHANGELOG.md`](#{REPOSITORY}CHANGELOG.md), one entry per release. Upgrade notes sit under **Upgrading** in the release that needs them.
  MDX

  RELEASE = /\A(?<label>\S+)(?: \((?<date>[^)]+)\))?\z/
  FENCE = /\A\s*(```|~~~)/
  CODE_SPAN = /(`+)(?:(?!\1).)+?\1/
  AUTOLINK = /<(https?:\/\/[^>\s]+)>/
  LINK_TARGET = /\]\(([^)\s]+)\)/

  module_function

  # CHANGELOG.md's Markdown in, the page's MDX out. Reads and writes nothing.
  def render(markdown)
    releases = markdown.split(/^## /).drop(1)
    raise ArgumentError, "CHANGELOG.md has no ## release headings" if releases.empty?

    HEADER + releases.map { |release| update(release) }.join
  end

  def update(release)
    heading, body = release.split("\n", 2)
    match = RELEASE.match(heading.strip) or raise ArgumentError, "Unrecognised release heading: ## #{heading}"
    description = match[:label] == "Unreleased" ? "Not released yet" : match[:date]
    attributes = [ %(label="#{attribute(match[:label])}"), (%(description="#{attribute(description)}") if description) ].compact.join(" ")

    "\n<Update #{attributes}>\n\n#{body(body.to_s).strip}\n\n</Update>\n"
  end

  # Subsections become bold lines: every release has its own "Fixed", and
  # headings would give the page duplicate anchors. Code blocks pass through.
  def body(markdown)
    fenced = false
    markdown.lines(chomp: true).map do |line|
      if line.match?(FENCE)
        fenced = !fenced
        line
      elsif fenced then line
      elsif line.start_with?("### ") then "**#{text(line.delete_prefix("### ").strip)}**"
      else text(line)
      end
    end.join("\n")
  end

  # Escapes what MDX would read as JSX or an expression, outside code spans.
  def text(line)
    out = +""
    while (span = CODE_SPAN.match(line))
      out << prose(span.pre_match) << span[0]
      line = span.post_match
    end
    out << prose(line)
  end

  def prose(piece)
    piece
      .gsub(AUTOLINK) { "[#{$1}](#{$1})" }
      .gsub(LINK_TARGET) { "](#{link($1)})" }
      .gsub(/[{}<]/) { "\\#{$&}" }
  end

  def link(target)
    path, anchor = target.split("#", 2)
    return target if path.empty? || path.match?(/\A[a-z][a-z0-9+.-]*:/i)

    PAGES.fetch(target) { [ PAGES.fetch(path) { "#{REPOSITORY}#{path}" }, anchor ].compact.join("#") }
  end

  def attribute(value)
    value.gsub("&", "&amp;").gsub('"', "&quot;")
  end
end

if $PROGRAM_NAME == __FILE__
  File.write(DocsChangelog::TARGET, DocsChangelog.render(File.read(DocsChangelog::SOURCE, encoding: "UTF-8")))
  puts "docs/changelog.mdx"
end
