# Development only: a sign-in for local work. Production starts at /first_run.
if Rails.env.development?
  User.find_or_create_by!(email_address: "admin@example.com") do |user|
    user.name = "Demo Admin"
    user.password = "demo-password-123"
    user.role = "admin"
  end
  puts "Sign in as admin@example.com / demo-password-123. Run bin/rails meridian:demo for a fleet."
end
