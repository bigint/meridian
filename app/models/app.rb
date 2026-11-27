class App < ApplicationRecord
  include Deployable, Releases

  # A deploy, rollback or redeploy Meridian won't make, and why.
  class Refused < StandardError; end

  # What New app can make. Configs label theirs with meridian.kind.
  KINDS = %w[ static node rails other ].freeze
  # A config that only runs accessories, such as a Cloudflare Tunnel's
  # connectors: Kamal never deploys an app from it, so the board leaves it out.
  ACCESSORIES = "accessories"
  LABELLED_KINDS = [ *KINDS, ACCESSORIES ].freeze

  belongs_to :project
  has_many :assignments, dependent: :delete_all
  has_many :servers, -> { distinct }, through: :assignments
  has_many :placements, dependent: :nullify
  has_many :releases, -> { order(committed_at: :desc) }, dependent: :delete_all

  validates :service, :config_path, presence: true
  validates :kind, inclusion: { in: LABELLED_KINDS }

  scope :ordered, -> { order(:service, :destination) }
  scope :deployable, -> { where.not(kind: ACCESSORIES) }

  def name
    [ service, destination.presence ].compact.join(" · ")
  end

  def to_param
    [ id, service, destination.presence ].compact.join("-").parameterize
  end

  def destination_flag
    "-d #{destination}" if destination.present?
  end

  # A `kamal accessory` command for this config, as a person would type it.
  def accessory_command(verb, name, *flags)
    [ "kamal accessory", verb, name, "-c", config_path, destination_flag, *flags ].compact.join(" ")
  end

  def latest_release
    releases.first
  end

  # Takes what Kamal parsed, without saving. Sync calls this, fetches the
  # releases it needs from Git, and only then writes, in a short transaction.
  def assign_config(result, tree)
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
    # Git is the record: a label taken out of the config clears it.
    self.kind = labels["meridian.kind"].presence_in(LABELLED_KINDS) || "other"
    self.source_repo = labels["meridian.source"].presence

    shas = sources.index_with { tree.fetch(it).sha }
    @releases_due = shas != source_shas || releases.none?
    self.source_shas = shas
    self
  end

  # The files behind the app changed, or it has no releases yet.
  def releases_due?
    @releases_due
  end

  # Writes what assign_config took, and the releases fetched for it.
  def record_config(fetched_releases)
    save!
    record_assignments(roles)
    record_releases(fetched_releases)
  end

  private
    def record_assignments(roles)
      wanted = roles.flat_map { |role| role["hosts"].map { |host| [ Server.for_host(host).id, role["name"] ] } }
      wanted.each { |server_id, role| assignments.find_or_create_by!(server_id: server_id, role: role) }
      assignments.reject { [ it.server_id, it.role ].in?(wanted) }.each(&:destroy)
    end
end
