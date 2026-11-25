# The audit trail of everything Meridian did, and who asked for it.
class Event < ApplicationRecord
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :subject, polymorphic: true, optional: true

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  def self.record(action, subject: nil, actor: Current.user, **details)
    create!(action: action, subject: subject, actor: actor, details: details)
  end

  def actor_name
    actor&.display_name || "Meridian"
  end

  def summary
    details["summary"] || action.humanize
  end
end
