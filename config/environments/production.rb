require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # Behind kamal-proxy with TLS (the default), trust it and require HTTPS.
  # A plain-HTTP MERIDIAN_URL (e.g. trying it locally) turns both off.
  https = ENV.fetch("MERIDIAN_URL", "https://").start_with?("https://")
  config.assume_ssl = https

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = https

  # Skip http-to-https redirect for the default health check endpoint.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }
  # Every agent's snapshot is a job, four a minute per server. Keeping each
  # finished one (and its payload) for a day would grow the queue database
  # by gigabytes a day. Failed jobs are still kept.
  config.solid_queue.preserve_finished_jobs = false

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Answer only to MERIDIAN_URL's host (DNS rebinding, forged Host headers),
  # except the health check, which kamal-proxy calls by IP. Without a host
  # there is nothing to check against, so Meridian refuses to start rather
  # than answer to any host. The image's asset build needs no URL.
  host = begin
    URI(ENV.fetch("MERIDIAN_URL", "")).host.presence
  rescue URI::InvalidURIError
  end
  if host
    config.hosts << host
    config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
  elsif !ENV["SECRET_KEY_BASE_DUMMY"]
    abort "MERIDIAN_URL must be the address Meridian is reached at, such as https://meridian.example.com. See docs/reference/environment.mdx."
  end
end
