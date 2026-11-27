# The name of a secret a Kamal config references. Values are write-only:
# they go straight from the form to the Git host's encrypted secrets store and
# are never assigned to a model, logged, enqueued or broadcast.
class SecretName < ApplicationRecord
  FORMAT = /\A(?!GITHUB_)[A-Z_][A-Z0-9_]{0,127}\z/

  belongs_to :project

  normalizes :name, with: ->(name) { name.to_s.strip.upcase }
  validates :name, format: { with: FORMAT, message: "must be letters, digits and underscores, not starting with GITHUB_" }, uniqueness: { scope: :project_id }

  def self.record(project)
    # Reloaded: a second sync of the same project in one job would otherwise
    # read the apps the first one left in memory.
    references = project.apps.reload.each_with_object(Hash.new { |h, k| h[k] = [] }) do |app, names|
      app.secret_names.each { names[normalize_value_for(:name, it)] << app.name }
    end
    # GitHub can't store some names (GITHUB_TOKEN is its own). A config that
    # uses one must not stop every sync of the project.
    references.select! { |name, _| name.match?(FORMAT) }

    references.each do |name, apps|
      record = project.secret_names.find_or_initialize_by(name: name)
      record.update!(apps: apps.uniq.sort) if record.new_record? || record.apps != apps.uniq.sort
    end

    # A name sync recorded and nobody set goes with its last reference. One
    # that was set, or that was added by hand, stays, referenced by nothing.
    project.secret_names.where.not(name: references.keys).each do |secret|
      next unless secret.referenced?
      secret.last_set_at ? secret.update!(apps: []) : secret.delete
    end
  end

  def set(value, actor:)
    raise ArgumentError, "Value can't be blank" if value.to_s.empty?

    project.git.put_secret(name, value.to_s)
    update!(last_set_at: Time.current)
    Event.record("secret.set", subject: self, actor: actor, summary: "Set #{name} on #{project.repo_full_name}")
  end

  def referenced?
    apps.any?
  end
end
