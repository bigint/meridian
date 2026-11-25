# Runs bin/kamal-parse over files fetched from an infra repository.
#
# The parse happens in a fresh Ruby process with an empty environment, inside
# a temporary directory holding only those files, so ERB in a config cannot
# read Meridian's credentials. See docs/decisions.md.
class KamalConfig
  SCRIPT = Rails.root.join("bin/kamal-parse").to_s
  KAMAL_VERSION = Gem.loaded_specs.fetch("kamal").version.to_s
  TIMEOUT = 60.seconds
  PASSTHROUGH_ENV = %w[ BUNDLE_PATH BUNDLE_WITHOUT BUNDLE_DEPLOYMENT BUNDLE_FROZEN GEM_HOME GEM_PATH ]

  class Error < StandardError; end

  # files:   { "config/deploy.yml" => "service: web\n..." }
  # entries: [ { "path" => "config/deploy.yml", "destination" => nil } ]
  def self.parse(files, entries)
    Dir.mktmpdir("meridian-parse") do |dir|
      files.each do |path, content|
        target = File.expand_path(path, dir)
        raise Error, "Refusing path outside checkout: #{path}" unless target.start_with?("#{dir}/")
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, content)
      end

      JSON.parse(run(dir, JSON.generate(configs: entries))).fetch("configs")
    end
  end

  def self.run(dir, input)
    env = ENV.slice(*PASSTHROUGH_ENV).merge("BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s, "PATH" => "/usr/local/bin:/usr/bin:/bin", "HOME" => dir, "LANG" => "C.UTF-8")
    Open3.popen3(env, RbConfig.ruby, "-rbundler/setup", SCRIPT, chdir: dir, unsetenv_others: true, pgroup: true) do |stdin, stdout, stderr, thread|
      stdin.write(input)
      stdin.close
      output = Thread.new { stdout.read }
      errors = Thread.new { stderr.read }

      unless thread.join(TIMEOUT)
        Process.kill("KILL", -thread.pid)
        raise Error, "Parsing timed out after #{TIMEOUT.inspect}"
      end

      raise Error, "Parser failed: #{errors.value.lines.last(3).join.strip}" unless thread.value.success?
      output.value
    end
  end
  private_class_method :run
end
