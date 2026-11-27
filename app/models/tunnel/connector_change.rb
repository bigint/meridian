# Changes which servers run a tunnel's connectors, in the connector config's
# own text. An added server gets a copy of an existing connector entry with
# its host and hostname swapped in, the way you'd add one by hand; a dropped
# server loses its entry and the comments just above it. Every other line
# (other accessories, anchors, comments) stays as it was, and Kamal checks the
# result, which must start connectors on exactly the picked servers and leave
# every other accessory alone, before Meridian proposes it.
class Tunnel::ConnectorChange
  include ActiveModel::Validations
  include Tunnel::Covering

  ENTRY = /\A  ([\w.-]+):/ # a key directly under accessories:
  TOP_LEVEL = /\A[^\s#]/

  attr_reader :tunnel, :hosts

  validate :hosts_well_formed, :one_config, :one_host_per_connector, :some_hosts, :something_changes
  validate :kamal_accepts_it, if: -> { errors.none? }

  def initialize(tunnel, hosts:)
    @tunnel, @hosts = tunnel, Array(hosts).compact_blank.uniq
  end

  def project = tunnel.project
  def config = tunnel.configs.first
  def path = config.config_path
  def current = tunnel.connector_hosts
  def added = hosts - current
  def removed = current - hosts
  def changed? = added.any? || removed.any?

  # The config as it is on the default branch now.
  def source = @source ||= project.git.file(path).content

  def apps = @apps ||= project.apps.deployable.includes(:servers).ordered.to_a
  def coverage = @coverage ||= Tunnel.coverage(apps, hosts)

  # The servers to pick from: every one the project's apps run on, and every
  # one that runs a connector now.
  def candidates = (apps.flat_map(&:servers) + tunnel.connectors.filter_map(&:server)).uniq.sort_by(&:name)

  # Kamal forgets a connector once its entry is gone, so remove it first.
  def remove_commands = removed_connectors.map { config.accessory_command("remove", it.name, "-y") }
  def boot_commands = added.map { config.accessory_command("boot", name_for(it)) }

  def content
    @content ||= sync_server_hosts(edit_accessories(source.lines)).join
  end

  def title
    changes = [ ("add #{added.to_sentence}" if added.any?), ("remove #{removed.to_sentence}" if removed.any?) ].compact
    "feat(#{tunnel.name}): #{changes.join("; ")} as Cloudflare Tunnel connectors"
  end

  def body
    <<~MARKDOWN
      Changes which servers run a connector of Cloudflare Tunnel #{tunnel.name}, in `#{path}`. Proposed by Meridian.

      #{added.map { "- Adds a connector on `#{it}`" }.join("\n")}
      #{removed.map { "- Removes the connector on `#{it}`" }.join("\n")}

      ### By hand

      #{by_hand.join("\n\n")}
    MARKDOWN
  end

  def submit(actor)
    return false unless valid?

    project.propose(files: { path => content }, title: title, body: body, actor: actor, slug: "tunnel-#{tunnel.name}")
  end

  private
    # What a person has to run or check around the merge, if anything.
    def by_hand
      steps = []
      if remove_commands.any?
        steps << "Before merging, stop the dropped connectors (once merged, Kamal no longer knows them):\n\n```\n#{remove_commands.join("\n")}\n```"
      end
      if boot_commands.any?
        steps << "After merging, start the new ones, with `#{tunnel.secret_name}` in the environment:\n\n```\n#{boot_commands.join("\n")}\n```"
      end
      if gaps.any?
        steps << "Cloudflare can send any routed hostname to any connector. Not on every connector's server yet: #{gaps.map { "#{it.app.name} (missing on #{it.missing.join(", ")})" }.join("; ")}."
      end
      steps
    end

    def removed_connectors = tunnel.connectors.select { removed.include?(it.host) }
    def template = tunnel.connectors.find { hosts.include?(it.host) } || tunnel.connectors.first

    # Named the way the file names them: production calls kamal-blr-01's
    # connector cloudflared-blr-01, so kamal-fra-01's is cloudflared-fra-01.
    # Otherwise cloudflared-<first DNS label>. Unique either way.
    def name_for(host)
      label, model = Tunnel.label_for(host), Tunnel.label_for(template.host)
      suffix = template.name.delete_prefix("cloudflared-")
      dropped = model.end_with?(suffix) ? model.delete_suffix(suffix) : ""
      base = "cloudflared-#{label.start_with?(dropped) ? label.delete_prefix(dropped) : label}"
      taken = tunnel.connectors.map(&:name) - removed_connectors.map(&:name) + added.take_while { it != host }.map { name_for(it) }
      return base unless taken.include?(base)
      (2..).lazy.map { "#{base}-#{it}" }.find { !taken.include?(it) }
    end

    # Each entry under accessories:, from the comments just above its key to
    # the next entry's, as { name => range }.
    def entries(lines)
      start = lines.index { it.chomp == "accessories:" } or return {}
      stop = (start + 1...lines.size).find { lines[it] =~ TOP_LEVEL } || lines.size
      firsts = (start + 1...stop).select { lines[it] =~ ENTRY }.map do |key|
        first = key
        first -= 1 while first > start + 1 && lines[first - 1] =~ /\A  #/
        [ lines[key][ENTRY, 1], first, key ]
      end
      firsts.each_with_index.to_h { |(name, first, key), index| [ name, { range: first...(firsts[index + 1]&.second || stop), key: key } ] }
    end

    def edit_accessories(lines)
      found = entries(lines)
      connectors = tunnel.connectors.map(&:name).select { found.key?(it) }
      return lines if connectors.empty?

      dropped = removed_connectors.map(&:name)
      keep = connectors - dropped
      # New entries go after the last connector kept, or where the first one was.
      anchor = keep.last || connectors.first

      # The entry to copy, from its key on, and a blank line between entries
      # if the file puts one there.
      model = found.fetch(template.name)
      core = trim(lines[model[:key]...model[:range].end])
      gap = connectors.any? { lines[found[it][:range].end - 1].strip.empty? } ? [ "\n" ] : []
      fresh = added.flat_map { |host| gap + connector_lines(core, host) }

      output = found.flat_map do |name, entry|
        block = lines[entry[:range]]
        if name == anchor
          keep.include?(name) ? trim(block) + fresh + tail(block) : fresh.drop(gap.size) + tail(block)
        elsif dropped.include?(name) then []
        else block
        end
      end
      lines[0...found.values.first[:range].begin] + output + lines[found.values.last[:range].end..]
    end

    def connector_lines(core, host)
      label = Tunnel.label_for(host)
      core.join
        .sub(ENTRY, "  #{name_for(host)}:")
        .gsub(/^(\s+host:\s*)#{Regexp.escape(template.host)}(?=\s|$)/) { "#{$1}#{host}" }
        .gsub(/^(\s+hostname:\s*)\S+/) { "#{$1}#{label}" }
        .lines
    end

    def trim(block) = block.reverse.drop_while { it.strip.empty? }.reverse
    def tail(block) = block.reverse.take_while { it.strip.empty? }.reverse

    # The primary role's hosts list follows: an added server is listed, and a
    # dropped one leaves the list unless another accessory still runs there.
    def sync_server_hosts(lines)
      start = lines.index { it.chomp == "servers:" } or return lines
      stop = (start + 1...lines.size).find { lines[it] =~ TOP_LEVEL } || lines.size
      items = (start + 1...stop).select { lines[it] =~ /\A\s+- / }
      return lines if items.empty?

      listed = items.to_h { [ lines[it][/\A\s+- ["']?([^\s:"'#]+)/, 1], it ] }
      accessories = entries(lines).values.flat_map { lines[it[:range]] }.join
      drop = removed.filter_map { |host| listed[host] unless accessories.match?(/(host:\s*|-\s*)#{Regexp.escape(host)}(\s|$)/) }
      indent = lines[items.last][/\A\s+/]
      lines = lines.dup
      lines.insert(items.last + 1, *added.reject { listed.key?(it) }.map { "#{indent}- #{it}\n" })
      drop.sort.reverse_each { lines.delete_at(it) }
      lines
    end

    # Hosts arrive in the URL, and Kamal evaluates ERB when it checks the
    # result, so anything that isn't plainly a host name is refused first.
    def hosts_well_formed
      bad = hosts.reject { it.is_a?(String) && it.match?(Server::HOST_FORMAT) }
      errors.add(:base, "Not a server name: #{bad.map(&:to_s).to_sentence}") if bad.any?
    end

    def one_config
      errors.add(:base, "Its connectors live in #{tunnel.configs.size} configs; edit them in Git") unless tunnel.configs.one?
    end

    def one_host_per_connector
      if tunnel.connectors.group_by(&:name).values.any?(&:many?)
        errors.add(:base, "A connector entry lists several hosts; edit it in Git")
      end
    end

    def some_hosts
      errors.add(:base, "Pick at least one server") if hosts.empty?
    end

    def something_changes
      errors.add(:base, "Pick servers to add or remove") unless changed?
    end

    # Never propose a config Kamal would reject, or one that touches anything
    # but the connectors.
    def kamal_accepts_it
      before, after = [ source, content ].map { KamalConfig.parse({ path => it }, [ { "path" => path, "destination" => nil } ]).sole }
      return errors.add(:base, "Kamal rejected the change: #{after.dig("error", "message")}") if after["error"]

      split = ->(result) { result["accessories"].partition { Tunnel.cloudflared?(it) } }
      connectors_after, others_after = split.(after)
      _, others_before = split.(before)
      errors.add(:base, "The change didn't come out as planned; edit #{path} in Git") unless
        connectors_after.flat_map { it["hosts"] }.sort == hosts.sort && others_after == others_before
    rescue GitHost::Error => error
      errors.add(:base, "Couldn't read #{path}: #{error.message.truncate(120)}")
    end
end
