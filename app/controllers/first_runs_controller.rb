# Creates the one user. Only reachable while there are no users, and only
# with the setup code from the server's log (User.setup_code).
class FirstRunsController < ApplicationController
  layout "auth"
  allow_unauthenticated_access
  before_action { redirect_to root_path if User.exists? }

  def show
    @user = User.new
    logger.info "Meridian setup code: #{User.setup_code}"
  end

  def create
    @user = User.new(params.expect(user: [ :name, :email_address, :password ]))
    if !ActiveSupport::SecurityUtils.secure_compare(params[:setup_code].to_s.strip.downcase, User.setup_code)
      @user.errors.add(:setup_code, "doesn't match the one in Meridian's log")
      render :show, status: :unprocessable_entity
    elsif @user.save
      start_new_session_for @user
      redirect_to projects_path, notice: "Welcome. Add your infra repository to begin."
    else
      render :show, status: :unprocessable_entity
    end
  end
end
