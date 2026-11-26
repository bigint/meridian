# Icons are Lucide's (vendor/lucide, added with bin/icons), inlined so they
# take currentColor. Views name them by meaning; this maps meaning to Lucide.
module IconsHelper
  ICONS = {
    board: "layout-grid", map: "map", apps: "box", servers: "server", activity: "activity",
    agents: "radio-tower", tunnels: "waypoints", secrets: "key-round", projects: "folder-git-2", settings: "settings", jobs: "list-checks",
    search: "search", plus: "plus", menu: "menu", chevron: "chevron-down", previous: "chevron-left", next: "chevron-right",
    collapse: "panel-left-close", expand: "panel-left-open", sign_out: "log-out", copy: "copy", copied: "check",
    info: "info", ok: "circle-check", warn: "triangle-alert", bad: "circle-x",
    system: "monitor", light: "sun", dark: "moon",
    cpu: "cpu", memory: "memory-stick", load: "gauge", disk: "hard-drive", download: "arrow-down", upload: "arrow-up",
    git_host: "folder-git-2", webhooks: "webhook", kamal: "ship", logs: "scroll-text", traffic: "arrow-left-right"
  }.freeze

  # Meridian's own mark: a globe with one meridian drawn on it.
  LOGO = '<circle cx="12" cy="12" r="8.5"/><ellipse cx="12" cy="12" rx="3.6" ry="8.5"/>'.freeze

  SHAPES = Hash.new do |shapes, name|
    svg = Rails.root.join("vendor/lucide", "#{ICONS.fetch(name)}.svg").read
    shapes[name] = svg[%r{<svg[^>]*>(.*)</svg>}m, 1].strip.freeze
  end

  # 16px unless the surrounding CSS sizes it (buttons, nav links…) or a
  # width and height are given.
  def icon(name, **options)
    shapes = name == :logo ? LOGO : SHAPES[name]
    tag.svg(shapes.html_safe, viewBox: "0 0 24 24", width: 16, height: 16, fill: "none", stroke: "currentColor", "stroke-width": 1.75,
      "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": true, **options)
  end
end
