require "open3"

# Runs bin/kamal-parse over files fetched from an infra repository.
#
# ERB in a Kamal config is arbitrary Ruby from the infra repository. The
# parse happens in a fresh Ruby process with an empty environment, in a
# temporary directory of its own holding only those files. In the image it
# also runs as its own user (MERIDIAN_PARSE_USER), through sudo, so it can't
# read Meridian's databases or, through /proc, the environment of Meridian's
# processes, where SECRET_KEY_BASE and the GitHub App's key live. Without
# that user (development, tests) it runs as Meridian's own user.
# See contributing/decisions.md.
class KamalConfig
  SCRIPT = Rails.root.join("bin/kamal-parse").to_s
  KAMAL_VERSION = Gem.loaded_specs.fetch("kamal").version.to_s
  TIMEOUT = 60.seconds
  PASSTHROUGH_ENV = %w[ BUNDLE_PATH BUNDLE_WITHOUT BUNDLE_DEPLOYMENT BUNDLE_FROZEN BUNDLE_APP_CONFIG GEM_HOME GEM_PATH ]

  class Error < StandardError; end

  # files:   { "config/deploy.yml" => "service: web\n..." }
  # entries: [ { "path" => "config/deploy.yml", "destination" => nil } ]
  def self.parse(files, entries)
    files.each_key do |path|
      raise Error, "Refusing path outside checkout: #{path}" unless inside_checkout?(path)
    end

    output = run(JSON.generate(files: files, configs: entries))
    begin
      JSON.parse(output).fetch("configs")
    rescue JSON::ParserError, KeyError
      raise Error, "The parser exited without a result"
    end
  end

  # The same check bin/kamal-parse makes where it writes the files.
  def self.inside_checkout?(path)
    File.expand_path(path.to_s, "/checkout").start_with?("/checkout/")
  end

  def self.run(input)
    env, *command = self.command
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Open3.popen3(env, *command, chdir: Dir.tmpdir, unsetenv_others: true, pgroup: true) do |stdin, stdout, stderr, thread|
      stdin.write(input)
      stdin.close
      output = Thread.new { stdout.read }
      errors = Thread.new { stderr.read }

      # As the parse user, `timeout` kills the parse; this is the backstop,
      # and the only limit without that user.
      unless thread.join(TIMEOUT + 5.seconds)
        begin
          Process.kill("KILL", -thread.pid)
        rescue Errno::EPERM, Errno::ESRCH
          # Another user's processes: theirs to end, and `timeout` will.
        end
        # The pipes close when this block returns; let the readers see EOF
        # first instead of dying on a stream closed under them.
        [ output, errors ].each { it.join(1) }
        raise Error, "Parsing timed out after #{TIMEOUT.inspect}"
      end

      # `timeout` ended it: sudo passes the KILL on, and dies of it too.
      status = thread.value
      timed_out = !status.success? && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= TIMEOUT.to_i
      raise Error, "Parsing timed out after #{TIMEOUT.inspect}" if timed_out
      raise Error, "Parser was killed by signal #{status.termsig}" if status.signaled?
      raise Error, "Parser failed: #{errors.value.lines.last(3).join.strip}" unless status.success?
      output.value
    end
  end

  # [ env, *argv ]. sudo resets the environment itself, so the parse's goes
  # on the command line, through env. sudo itself gets only PATH: started
  # with no environment at all, sudo 1.9.16 crashes.
  def self.command
    env = ENV.slice(*PASSTHROUGH_ENV).merge("BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s, "PATH" => "/usr/local/bin:/usr/bin:/bin", "HOME" => Dir.tmpdir, "LANG" => "C.UTF-8")
    ruby = [ RbConfig.ruby, "-rbundler/setup", SCRIPT ]

    if parse_user
      [ { "PATH" => "/usr/bin:/bin" }, "/usr/bin/sudo", "--non-interactive", "--user=#{parse_user}", "/usr/bin/env", "--ignore-environment",
        *env.map { |key, value| "#{key}=#{value}" }, "/usr/bin/timeout", "--signal=KILL", TIMEOUT.to_i.to_s, *ruby ]
    else
      [ env, *ruby ]
    end
  end

  def self.parse_user = ENV["MERIDIAN_PARSE_USER"].presence

  private_class_method :run, :command, :parse_user
end
