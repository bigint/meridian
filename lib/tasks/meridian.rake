namespace :meridian do
  desc "Print the code that creating the first admin asks for"
  task setup_code: :environment do
    puts User.setup_code
  end
end
