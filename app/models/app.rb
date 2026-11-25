class App < ApplicationRecord
  include Deployable, Releases

  KINDS = %w[ static node rails other ]

  belongs_to :project
  has_many :assignments, dependent: :delete_all
  has_many :servers, -> { distinct }, through: :assignments
  has_many :placements, dependent: :nullify
  has_many :releases, -> { order(committed_at: :desc) }, dependent: :delete_all
  has_many :previews, dependent: :delete_all

  validates :service, :config_path, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :ordered, -> { order(:service, :destination) }

  def name
    [ service, destination.presence ].compact.join(" · ")
  end

  def to_param
    [ id, service, destination.presence ].compact.join("-").parameterize
  end

  def destination_flag
    "-d #{destination}" if destination.present?
  end

  # The container name prefix Kamal uses for a role (see docs/architecture.md).
  def container_prefix(role)
    [ service, role, destination.presence ].compact.join("-")
  end

  def latest_release
    releases.first
  end

  def record_config(result, tree)
    destination = result["destination"]
    version_path = project.version_path(config_path, destination)
    sources = [ config_path, destination && project.destination_path(config_path, destination), (version_path if tree.key?(version_path)) ].compact

    self.service = result["service"]
    self.image = result["image"]
    self.hostnames = result["hostnames"]
    self.roles = result["roles"]
    self.accessories = result["accessories"]
    self.secret_names = result["secrets"]
    self.version_path = tree.key?(version_path) ? version_path : nil
    labels = result["labels"] || {}
    self.kind = labels["meridian.kind"] if KINDS.include?(labels["meridian.kind"])
    self.source_repo = labels["meridian.source"].presence || source_repo

    shas = sources.index_with { tree.fetch(it).sha }
    changed = shas != source_shas
    self.source_shas = shas
    save!

    record_assignments(result["roles"])
    record_releases if changed || releases.none?
  end

  private
    def record_assignments(roles)
      wanted = roles.flat_map { |role| role["hosts"].map { |host| [ Server.for_host(host).id, role["name"] ] } }
      wanted.each { |server_id, role| assignments.find_or_create_by!(server_id: server_id, role: role) }
      assignments.reject { [ it.server_id, it.role ].in?(wanted) }.each(&:destroy)
    end
end
