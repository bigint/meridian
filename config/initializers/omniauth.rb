# Optional OpenID Connect sign-in. Set OIDC_ISSUER, OIDC_CLIENT_ID and
# OIDC_CLIENT_SECRET (and optionally OIDC_NAME for the button label).
module Meridian
  def self.oidc? = ENV["OIDC_ISSUER"].present? && ENV["OIDC_CLIENT_ID"].present?
  def self.oidc_name = ENV.fetch("OIDC_NAME", "single sign-on")
end

if Meridian.oidc?
  Rails.application.config.middleware.use OmniAuth::Builder do
    provider :openid_connect,
      name: :oidc,
      issuer: ENV["OIDC_ISSUER"],
      discovery: true,
      scope: %i[ openid email profile ],
      response_type: :code,
      pkce: true,
      client_options: {
        identifier: ENV["OIDC_CLIENT_ID"],
        secret: ENV["OIDC_CLIENT_SECRET"],
        redirect_uri: ENV.fetch("OIDC_REDIRECT_URI") { "#{ENV.fetch("MERIDIAN_URL", "http://localhost:3000")}/auth/oidc/callback" }
      }
  end
end

OmniAuth.config.on_failure = ->(env) { Rack::Response.new([ "" ], 302, "Location" => "/auth/failure").finish }
