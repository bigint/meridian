module ApplicationCable
  # A page holds its agents' leases only while it says it is still open.
  # ActionCable never times out a silent client, so a laptop asleep or a dead
  # network kept its leases renewing until the server's TCP gave up, many
  # minutes on. The browser performs "renew" every ten seconds, and the renew
  # timer lets the lease lapse once the page has been silent for SILENCE.
  module Renewal
    extend ActiveSupport::Concern

    # How often a page says it is still open (the browser's renew timer).
    RENEW_EVERY = 10.seconds
    SILENCE = 75.seconds # a hidden tab's timers can slow to once a minute

    included do
      after_subscribe { @heard_at = Time.current }
    end

    def renew
      @heard_at = Time.current
    end

    private
      def heard_lately?
        @heard_at.present? && Time.current - @heard_at < SILENCE
      end
  end
end
