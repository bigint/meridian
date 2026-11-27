# Puma's settings. See https://puma.io/puma/Puma/DSL.html.
# One process with RAILS_MAX_THREADS threads (3 by default). Leave
# WEB_CONCURRENCY unset: Meridian runs one Puma process.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments.
# Solid Queue runs inside Puma by default. Set SOLID_QUEUE_IN_PUMA=false and run
# bin/jobs in a separate "job" role for large installs.
plugin :solid_queue unless ENV["SOLID_QUEUE_IN_PUMA"] == "false"

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
