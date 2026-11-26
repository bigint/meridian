# Development only: a sign-in for local work. Production starts at /first_run.
if Rails.env.development?
  User.find_or_create_by!(email_address: "admin@example.com") do |user|
    user.name = "Admin"
    user.password = "admin-password-123"
  end
  puts "Sign in as admin@example.com / admin-password-123."
end
