# Strict CSP: everything from this origin, inline scripts only with a nonce
# (the importmap tags get one automatically). Turbo's progress bar <style> uses
# the same nonce, so style-src accepts it too; style attributes stay blocked.
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
    policy.form_action :self
    policy.frame_ancestors :none
  end

  config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[ script-src style-src ]
  config.content_security_policy_nonce_auto = true
end
