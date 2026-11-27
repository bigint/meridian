module TunnelsHelper
  # A line on every tunnel: how many, and how many need attention.
  def tunnels_summary(tunnels)
    return "No Cloudflare Tunnel yet." if tunnels.none?

    problems = tunnels.count(&:problems?)
    total = pluralize(tunnels.size, "Cloudflare Tunnel")
    problems.zero? ? "#{total}. Every connector is running." : "#{total}. #{problems} #{problems == 1 ? "needs" : "need"} attention."
  end
end
