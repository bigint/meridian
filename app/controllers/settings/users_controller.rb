class Settings::UsersController < AdminController
  before_action :set_user, only: %i[ edit update destroy ]

  def index
    @users = User.order(:email_address)
  end

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params)
    if @user.save
      Event.record("user.created", subject: @user, summary: "Added #{@user.email_address} as #{@user.role}")
      redirect_to settings_users_path, notice: "#{@user.email_address} can now sign in."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    attributes = user_params
    attributes.delete(:password) if attributes[:password].blank?
    if last_admin_demoted?(attributes)
      redirect_to edit_settings_user_path(@user), alert: "There must always be one admin."
    elsif @user.update(attributes)
      @user.sessions.where.not(id: Current.session.id).destroy_all if attributes.key?(:password)
      Event.record("user.updated", subject: @user, summary: "Updated #{@user.email_address} (#{@user.role})")
      redirect_to settings_users_path, notice: "Saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @user == current_user
      redirect_to settings_users_path, alert: "You can't remove yourself."
    else
      @user.destroy
      Event.record("user.removed", summary: "Removed #{@user.email_address}")
      redirect_to settings_users_path, notice: "Removed #{@user.email_address}."
    end
  end

  private
    def set_user
      @user = User.find(params[:id])
    end

    def user_params
      params.expect(user: [ :name, :email_address, :password, :role ])
    end

    def last_admin_demoted?(attributes)
      @user.admin? && attributes[:role].present? && attributes[:role] != "admin" && User.admin.count == 1
    end
end
