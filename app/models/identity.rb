# A sign-in through an OpenID Connect provider.
class Identity < ApplicationRecord
  belongs_to :user

  def self.sign_in(auth)
    identity = find_by(provider: auth.provider, uid: auth.uid)
    return identity.user if identity

    email = auth.info&.email.to_s.downcase
    return if email.blank?

    user = User.find_by(email_address: email) || User.create!(email_address: email, name: auth.info.name, password: SecureRandom.base58(32))
    user.identities.create!(provider: auth.provider, uid: auth.uid)
    user
  end
end
