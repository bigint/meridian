module LogsHelper
  TONES = 8

  # What the viewer needs to know about each container it merges: a short
  # name that tells them apart, and a colour that stays the same for the
  # same container whenever the set doesn't change.
  def log_sources(placements)
    per_server = placements.group_by(&:server_id).transform_values(&:size)
    tones = placements.sort_by { [ it.server.name, it.name ] }.each_with_index.to_h { |placement, index| [ placement.id, index % TONES ] }

    placements.map do |placement|
      label = [ placement.server.short_name, (placement.role.presence || placement.kind if per_server[placement.server_id] > 1) ].compact.join(" · ")
      { id: placement.id, label: label, server: placement.server.name, title: "#{placement.name} on #{placement.server.name}", tone: tones[placement.id] }
    end
  end
end
