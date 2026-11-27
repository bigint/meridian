# The single row of install-wide settings.
class Account < ApplicationRecord
  include Locatable

  def self.current
    first_or_create!
  end
end
