# frozen_string_literal: true

require "rails/engine"

module Organizations
  class Engine < ::Rails::Engine
    isolate_namespace Organizations

    # Make has_organizations available on all ActiveRecord models.
    #
    # NOTE: We intentionally avoid explicit `require` calls for models here.
    # In Rails apps, Organizations models are loaded through Zeitwerk from app/models,
    # which keeps them reload-safe in development. Explicit requires would create
    # non-reloadable class references that cause STI errors with gems like Pay
    # after code reloads.
    initializer "organizations.active_record" do
      ActiveSupport.on_load(:active_record) do
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
