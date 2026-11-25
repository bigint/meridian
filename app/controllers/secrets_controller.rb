class SecretsController < ApplicationController
  require_admin only: %i[ create update ]
  rate_limit to: 20, within: 1.minute, only: %i[ create update ]

  def index
    @projects = Project.includes(secret_names: :last_set_by).order(:name)
  end

  # Adds a name (and optionally its first value).
  def create
    project = Project.find(params[:project_id])
    secret = project.secret_names.create!(name: params.expect(secret_name: [ :name ])[:name])
    secret.set(params[:secret_value], actor: current_user) if params[:secret_value].present?
    redirect_to secrets_path(anchor: "project-#{project.id}"), notice: "#{secret.name} added#{" and set" if secret.last_set_at}."
  rescue ActiveRecord::RecordInvalid => error
    redirect_to secrets_path, alert: error.record.errors.full_messages.to_sentence
  rescue GitHost::Error => error
    redirect_to secrets_path, alert: "GitHub refused: #{error.message.truncate(200)}"
  end

  # Sets or rotates a value. It is sent once and never stored or echoed.
  def update
    secret = SecretName.find(params[:id])
    secret.set(params[:secret_value], actor: current_user)
    redirect_to secrets_path(anchor: "project-#{secret.project_id}"), notice: "#{secret.name} set. Redeploy the apps that use it to pick it up."
  rescue ArgumentError => error
    redirect_to secrets_path, alert: error.message
  rescue GitHost::Error => error
    redirect_to secrets_path, alert: "GitHub refused: #{error.message.truncate(200)}"
  end
end
