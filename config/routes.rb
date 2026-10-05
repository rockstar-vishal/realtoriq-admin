Rails.application.routes.draw do
  # Reveal health status on /up
  get "up" => "rails/health#show", as: :rails_health_check

  # turbo-rails8 pushes marketplace projects and enquiries here. Authenticated
  # by HMAC, not by a broker JWT. The URL is whatever is stored as
  # realtoriq.webhook_url on the turbo side.
  post "turbo/events", to: "turbo/events#create"

  # Active Storage mounts its own direct-upload endpoint. It sits outside our
  # JWT auth and enforces none of the per-purpose size or type rules, so anyone
  # able to fetch a CSRF token could mint upload tickets against our storage.
  # Shadowed here — declared before the engine's routes, so this wins — leaving
  # /api/v1/uploads as the only way to get one.
  #
  # The routes *underneath* it stay: the client still PUTs the file to the disk
  # or S3 service URL, and blobs still serve through the usual paths.
  match "/rails/active_storage/direct_uploads",
    to: ->(_env) {
      [ 404,
        { "content-type" => "application/json" },
        [ { error: { code: "not_found", message: "Not found" } }.to_json ] ]
    },
    via: :all

  namespace :admin do
    root to: "dashboard#show"

    resource :session, only: %i[new create destroy]

    resources :firms, param: :slug do
      member do
        patch :activate
        patch :suspend
      end

      scope module: :firms do
        resources :contact_channels, only: %i[update] do
          member do
            post :send_code
            patch :mark_verified
            patch :reset
          end
        end

        resources :subscriptions, only: %i[create] do
          member do
            patch :renew
            patch :cancel
          end
        end
      end
    end

    resources :plans, except: %i[show]

    # Skills & Trainings. No show: the edit screen is the detail screen, and
    # what a broker sees comes from the API.
    resources :trainings, except: %i[show] do
      member do
        patch :activate
        patch :archive
      end
    end

    namespace :masters do
      resources :cities, param: :slug, except: %i[show]
      resources :localities, except: %i[show]
      # Builders are addressed by id: firm-owned ones can share a slug with the
      # global list, so a slug no longer identifies a single row.
      resources :builders, except: %i[show]
      resources :typologies, except: %i[show]
      resources :lead_sources, except: %i[show]
      resources :lead_statuses, except: %i[show]
      resources :property_types, except: %i[show]
    end
  end

  # The broker API. Versioned from the first commit so the React app never has
  # to guess which shape it is talking to.
  namespace :api do
    namespace :v1 do
      post   "auth/otp",     to: "auth#request_code"
      post   "auth/verify",  to: "auth#verify"
      post   "auth/refresh", to: "auth#refresh"
      delete "auth/session", to: "auth#sign_out"

      get "me",        to: "me#show"
      get "reference", to: "reference#index"

      # Websites post leads here. The key in Authorization picks the firm.
      # These actions do not use a broker JWT.
      post "inbound/:channel/projects", to: "inbound_leads#create", defaults: { kind: "projects" }
      post "inbound/:channel/properties", to: "inbound_leads#create", defaults: { kind: "properties" }
      get "inbound_credentials", to: "inbound_credentials#show"
      post "inbound_credentials/rotate", to: "inbound_credentials#rotate"

      resources :notifications, only: %i[index] do
        collection do
          get :unread_count
          post :mark_all_read
          post :test
        end
        member { patch :read }
      end

      get    "push_subscriptions", to: "push_subscriptions#show"
      post   "push_subscriptions", to: "push_subscriptions#create"
      delete "push_subscriptions", to: "push_subscriptions#destroy"
      get    "push_subscriptions/vapid_public_key", to: "push_subscriptions#vapid_public_key"

      resources :users, only: %i[index create show update] do
        resources :managers, only: %i[create destroy], controller: "user_managers",
          param: :manager_id
      end
      # The home screen. One request rather than six, and scoped to the caller:
      # an agent gets no money block at all.
      get "dashboard", to: "dashboard#show"

      # Grouped reads over leads and bookings. No tables of their own.
      # Bookings and revenue are manager-only; the lead reports are not.
      get "reports/source_status", to: "reports#source_status"
      get "reports/dead_leads", to: "reports#dead_leads"
      get "reports/bookings", to: "reports#bookings"
      get "reports/revenue", to: "reports#revenue"
      get "reports/assignees", to: "reports#assignees"

      # No destroy: the design has no delete. `Dead` is the terminal state, and
      # it carries a reason so the dead-leads report can explain itself.
      resources :leads, only: %i[index create show update] do
        collection do
          get :import_template, to: "lead_imports#template"
          post :import, to: "lead_imports#create"
        end

        member do
          post :status
          post :matches
        end

        # Flat controller names on purpose — an Api::V1::Leads module would
        # shadow the top-level Leads:: service namespace.
        resources :activities, only: %i[index create], controller: "lead_activities"
        resources :followups, only: %i[index create], controller: "lead_followups"
        resources :visits, only: %i[index create update], controller: "lead_visits"
        resources :projects, only: %i[create destroy], controller: "lead_projects"
        resources :properties, only: %i[create destroy], controller: "lead_properties"
        resources :visit_passes, only: %i[create], controller: "lead_visit_passes" do
          member { post :refresh }
        end
      end

      # Skills & Trainings. Read-only for brokers; ops publish from /admin.
      # The note is singular: one per broker per training, saved in place.
      resources :trainings, only: %i[index show] do
        resource :note, only: %i[update], controller: "training_notes"
      end

      resources :uploads, only: %i[create]

      # Inventory. No destroy anywhere: the design has none, a building with
      # listings can't go, and archiving is a status change.
      resources :builders, only: %i[index create]
      resources :buildings, only: %i[index create update]

      resources :projects, only: %i[index create show update] do
        # Typeahead. A collection route, so Rails matches it before :id and
        # "search" is never looked up as a project.
        collection { get :search }

        member do
          get :visitors
          get :marketplace_leads
          get :mapped_customers
          post :share_link
          post :lead_matches
          patch :portal_codes
          # Photos live on the detail screen, not the create form.
          post   "photos", to: "projects#add_photos"
          delete "photos/:photo_id", to: "projects#remove_photo", as: :photo
        end
      end

      resources :properties, only: %i[index create show update] do
        # Directory of other firms' shared listings. A collection route, so
        # "marketplace" is never looked up as a property id.
        collection do
          get :marketplace, action: :marketplace_index, as: :marketplace_index
        end

        member do
          get :visitors
          get :mapped_customers
          get :marketplace
          post :lead_matches
          patch :portal_codes
          post   "photos", to: "properties#add_photos"
          delete "photos/:photo_id", to: "properties#remove_photo", as: :photo
        end
      end

      # Bookings and the money against them. Managers and super admins only —
      # these are commission records.
      resources :bookings, only: %i[index create show update] do
        member { post :cancel }

        resources :documents, only: %i[create destroy], controller: "booking_documents"
        resources :invoices, only: %i[index create]
        resources :collections, only: %i[index create]
      end

      scope :firm do
        resources :contact_channels, only: %i[index] do
          member do
            post :request_code
            post :verify
          end
        end
      end
    end
  end

  root to: redirect("/admin")
end
