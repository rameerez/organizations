# frozen_string_literal: true

require "rails/engine"

module Organizations
  class Engine < ::Rails::Engine
    isolate_namespace Organizations

    # Autoload paths
    config.autoload_paths << File.expand_path("models", __dir__)
    config.autoload_paths << File.expand_path("models/concerns", __dir__)

    initializer "organizations.autoload", before: :set_autoload_paths do |app|
      app.config.autoload_paths << root.join("lib")
      app.config.autoload_paths << root.join("lib/organizations/models")
      app.config.autoload_paths << root.join("lib/organizations/models/concerns")
    end

    # Load models when ActiveRecord is ready
    initializer "organizations.active_record" do
      ActiveSupport.on_load(:active_record) do
        require "organizations/models/organization"
        require "organizations/models/membership"
        require "organizations/models/invitation"
        require "organizations/models/concerns/has_organizations"

        # Make has_organizations available on all AR models
        extend Organizations::Models::Concerns::HasOrganizations::ClassMethods
      end
    end

    # Include controller helpers in ActionController::Base
    initializer "organizations.action_controller" do
      ActiveSupport.on_load(:action_controller_base) do
        include Organizations::ControllerHelpers
      end
    end

    # Support API-only apps (ActionController::API)
    initializer "organizations.action_controller_api" do
      ActiveSupport.on_load(:action_controller_api) do
        include Organizations::ControllerHelpers
      end
    end

    # Include view helpers
    initializer "organizations.action_view" do
      ActiveSupport.on_load(:action_view) do
        include Organizations::ViewHelpers
      end
    end

    # Map authorization errors to HTTP 403
    initializer "organizations.rescue_responses" do |app|
      if app.config.respond_to?(:action_dispatch) && app.config.action_dispatch.respond_to?(:rescue_responses)
        app.config.action_dispatch.rescue_responses.merge!(
          "Organizations::NotAuthorized" => :forbidden,
          "Organizations::NotAMember" => :forbidden
        )
      end
    end

    # Add generator paths
    config.generators do |g|
      g.templates.unshift File.expand_path("../../generators", __dir__)
    end

    # Configure engine assets (if any)
    # initializer "organizations.assets" do |app|
    #   app.config.assets.precompile += %w[organizations/application.css organizations/application.js]
    # end
  end
end
