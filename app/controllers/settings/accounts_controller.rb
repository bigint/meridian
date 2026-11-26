class Settings::AccountsController < AdminController
  def show
    @account = Account.current
  end

  def update
    @account = Account.current
    if @account.update(params.expect(account: [ :name, :preview_domain, :preview_hostnames, :preview_ttl_days, :preview_selector, :location_name, :latitude, :longitude ]))
      Event.record("settings.updated", subject: @account, summary: "Updated settings")
      redirect_to settings_account_path, notice: "Settings saved."
    else
      render :show, status: :unprocessable_entity
    end
  end
end
