Rails.application.routes.draw do
  root "boards#show"

  resource :board, only: :show
  resource :jump, only: :show
  resource :map, only: :show
  resources :apps, only: %i[ index show new create ] do
    scope module: :apps do
      resources :deploys, only: :create
      resources :rollbacks, only: :create
      resource :redeploy, only: :create
      resource :log, only: :show
      resource :traffic, only: :show
    end
  end
  resources :placements, only: [] do
    scope module: :placements do
      resource :log, only: :show
    end
  end
  resources :servers, only: %i[ index show update ]
  resource :traffic, only: :show
  resources :events, only: :index
  resources :secrets, only: %i[ index create update ]
  namespace :tunnels do
    resource :setup, only: :show
    resource :connectors, only: %i[ edit update ]
  end
  resources :tunnels, only: :index
  resources :agent_tokens, only: %i[ index create destroy ], path: "agents"

  namespace :agent do
    resources :snapshots, only: :create
  end
  resources :projects do
    scope module: :projects do
      resource :sync, only: :create
      resource :workflow, only: :create
    end
  end

  resource :session, only: %i[ new create destroy ]
  resource :first_run, only: %i[ show create ]

  namespace :settings do
    root "accounts#show"
    resource :account, only: %i[ show update ]
    resource :user, only: :update
  end

  mount MissionControl::Jobs::Engine, at: "/jobs"

  get "up" => "rails/health#show", as: :rails_health_check
end
