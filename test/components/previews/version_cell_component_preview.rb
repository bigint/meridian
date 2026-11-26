# One app on one server: the version it runs, tinted by drift state.
class VersionCellComponentPreview < ViewComponent::Preview
  Named = Struct.new(:name)

  def all_states
    cells = Drift::STATES.map do |state|
      versions = { "missing" => [], "unknown" => [], "drifted" => [ "v41" ] }.fetch(state, [ "v42" ])
      Board::Cell.new(app: Named.new("web"), server: Named.new("aps2-az1-node-01"), state: state, versions: versions, roles: [ "web" ], health: nil, release: "v42")
    end
    render_with_template(locals: { cells: cells })
  end
end
