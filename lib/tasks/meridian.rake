namespace :meridian do
  desc "Seed a demo fleet: 500 servers, 200 apps, realistic drift (SERVERS=, APPS= to change)"
  task demo: :environment do
    servers, apps = ENV.fetch("SERVERS", 500).to_i, ENV.fetch("APPS", 200).to_i
    project = Meridian::Demo.new(servers: servers, apps: apps).call
    puts "Seeded #{project.name}: #{servers} servers, #{apps} apps. Open the board to look around."
  end

  desc "Print the code that creating the first admin asks for"
  task setup_code: :environment do
    puts User.setup_code
  end
end
