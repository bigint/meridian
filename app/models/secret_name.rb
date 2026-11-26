# The name of a secret a Kamal config references. Values are write-only:
# they go straight from the form to the Git host's encrypted secrets store and
# are never assigned to a model, logged, enqueued or broadcast.
class SecretName < ApplicationRecord
  FORMAT = /\A(?!GITHUB_)[A-Z_][A-Z0-9_]{0,127}\z/

  belongs_to :project
  belongs_to :last_set_by, class_name: "User", optional: true

  normalizes :name, with: ->(name) { name.to_s.strip.upcase }
  validates :name, format: { with: FORMAT, message: "must be letters, digits and underscores, not starting with GITHUB_" }, uniqueness: { scope: :project_id }

  def self.record(project)
    references = project.apps.each_with_object(Hash.new { |h, k| h[k] = [] }) do |app, names|
      app.secret_names.each { names[it] << app.name }
    end

    references.each do |name, apps|
      record = project.secret_names.find_or_initialize_by(name: name)
      record.update!(apps: apps.sort) if record.new_record? || record.apps != apps.sort
    end
    project.secret_names.where.not(name: references.keys).where(last_set_at: nil).delete_all
  end

  def set(value, actor:)
    raise ArgumentError, "Value can't be blank" if value.to_s.empty?

    project.git.put_secret(name, value.to_s)
    update!(last_set_at: Time.current, last_set_by: actor)
    Event.record("secret.set", subject: self, actor: actor, summary: "Set #{name} on #{project.repo_full_name}")
  end

  def referenced?
    apps.any?
  end
end
