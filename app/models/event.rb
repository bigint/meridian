# The audit trail of everything Meridian did, and who asked for it.
class Event < ApplicationRecord
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :subject, polymorphic: true, optional: true

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  # The actor's name is kept in the details too, so the trail still says who
  # it was after that person is removed (actor_id is then nulled).
  def self.record(action, subject: nil, actor: Current.user, **details)
    details[:actor_name] = actor.display_name if actor
    create!(action: action, subject: subject, actor: actor, details: details)
  end

  def actor_name
    actor&.display_name || details["actor_name"]&.then { "#{it} (removed)" } || "Meridian"
  end

  def summary
    details["summary"] || action.humanize
  end
end
