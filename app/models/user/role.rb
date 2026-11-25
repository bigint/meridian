# Viewers read. Deployers also deploy and roll back. Admins do everything else.
module User::Role
  extend ActiveSupport::Concern

  ROLES = %w[ viewer deployer admin ].freeze

  included do
    enum :role, ROLES.index_by(&:itself), default: "viewer", validate: true
  end

  def can_deploy?
    deployer? || admin?
  end
end
