# The one user's own name, email address and password, on the Settings page.
class Settings::UsersController < ApplicationController
  def update
    @user = User.find(current_user.id) # a failed save must not change who the layout shows
    attributes = params.expect(user: [ :name, :email_address, :password ])
    attributes.delete(:password) if attributes[:password].blank?
    if @user.update(attributes)
      @user.sessions.where.not(id: Current.session.id).destroy_all if attributes.key?(:password)
      Event.record("user.updated", subject: @user, summary: "Updated your account")
      redirect_to settings_account_path, notice: "Account saved."
    else
      @account = Account.current
      render "settings/accounts/show", status: :unprocessable_entity
    end
  end
end
