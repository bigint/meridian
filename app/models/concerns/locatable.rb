# A place on the map: a server, or the install's own location.
module Locatable
  extend ActiveSupport::Concern

  included do
    validates :latitude, numericality: { in: -90..90 }, allow_nil: true
    validates :longitude, numericality: { in: -180..180 }, allow_nil: true
  end

  def located?
    latitude && longitude
  end
end
