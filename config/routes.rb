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
    end
  end
  resources :servers, only: %i[ index show update ]
  resources :events, only: :index
  resources :secrets, only: %i[ index create update ]
  resources :previews, only: %i[ index destroy ]
  resources :agent_tokens, only: %i[ index create destroy ], path: "agents"

  namespace :webhooks do
    resource :github, only: :create, controller: "githubs"
  end

  namespace :agent do
    resources :snapshots, only: :create
  end
  resources :projects do
    scope module: :projects do
      resource :sync, only: :create
      resource :workflow, only: :create
    end
  end

  resource :session
  resource :first_run, only: %i[ show create ]
  get "auth/:provider/callback", to: "sessions/omniauths#create", as: :omniauth_callback
  get "auth/failure", to: "sessions/omniauths#failure"

  namespace :settings do
    root "accounts#show"
    resource :account, only: %i[ show update ]
    resources :users, except: :show
  end

  mount MissionControl::Jobs::Engine, at: "/jobs"

  get "up" => "rails/health#show", as: :rails_health_check
end
