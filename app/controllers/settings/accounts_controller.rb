class Settings::AccountsController < ApplicationController
  def show
    @account = Account.current
    @user = current_user
  end

  def update
    @account = Account.current
    if @account.update(params.expect(account: [ :name, :location_name, :latitude, :longitude ]))
      Event.record("settings.updated", subject: @account, summary: "Updated settings")
      redirect_to settings_account_path, notice: "Settings saved."
    else
      @user = current_user
      render :show, status: :unprocessable_entity
    end
  end
end
