# Strict CSP: everything from this origin, inline scripts only with a nonce
# (the importmap tags get one automatically).
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src :self
    policy.style_src :self
    policy.img_src :self, :data
    policy.font_src :self
    policy.connect_src :self
    policy.object_src :none
    policy.base_uri :self
    policy.form_action :self, "https://github.com", *([ ENV["OIDC_ISSUER"] ] if ENV["OIDC_ISSUER"].present?)
    policy.frame_ancestors :none
  end

  config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[ script-src ]
  config.content_security_policy_nonce_auto = true
end
