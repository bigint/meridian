# Creates the first admin. Only reachable while there are no users.
class FirstRunsController < ApplicationController
  layout "auth"
  allow_unauthenticated_access
  before_action { redirect_to root_path if User.exists? }

  def show
    @user = User.new
  end

  def create
    @user = User.new(params.expect(user: [ :name, :email_address, :password ]).merge(role: "admin"))
    if @user.save
      start_new_session_for @user
      redirect_to projects_path, notice: "Welcome. Add your infra repository to begin."
    else
      render :show, status: :unprocessable_entity
    end
  end
end
