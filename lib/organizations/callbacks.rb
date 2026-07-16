# frozen_string_literal: true

module Organizations
  # Centralized callback dispatch module.
  # Handles executing callbacks with error isolation - callbacks should never
  # break the main organization operations.
  #
  # @example Dispatching a callback
  #   Callbacks.dispatch(:organization_created, organization: org, user: user)
  #
  module Callbacks
    # Supported callback events
    EVENTS = %i[
      organization_created
      member_invited
      member_joined
      member_removed
      role_changed
      ownership_transferred
      join_request_created
      join_request_approved
      join_request_rejected
    ].freeze

    module_function

    # Dispatch a callback event.
    # By default callbacks are isolated (errors logged, not raised).
    # Pass strict: true when callback failures must abort the operation.
    # @param event [Symbol] The event type (e.g., :organization_created)
    # @param strict [Boolean] When true, callback errors are re-raised
    # @param context_data [Hash] Data to pass to the callback via CallbackContext
    def dispatch(event, strict: false, **context_data)
      callback = callback_for(event)
      return unless callback

      context = CallbackContext.new(event: event, **context_data)
      strict ? execute_strictly(callback, context) : execute_safely(event, callback, context)
    end

    # Maps each event to its Configuration reader. Adding an event = one
    # entry here + the EVENTS list + a Configuration attr/block method.
    CALLBACK_READERS = {
      organization_created: :on_organization_created_callback,
      member_invited: :on_member_invited_callback,
      member_joined: :on_member_joined_callback,
      member_removed: :on_member_removed_callback,
      role_changed: :on_role_changed_callback,
      ownership_transferred: :on_ownership_transferred_callback,
      join_request_created: :on_join_request_created_callback,
      join_request_approved: :on_join_request_approved_callback,
      join_request_rejected: :on_join_request_rejected_callback
    }.freeze

    # Get the callback proc for an event
    # @param event [Symbol] The event type
    # @return [Proc, nil]
    def callback_for(event)
      config = Organizations.configuration
      return nil unless config

      reader = CALLBACK_READERS[event]
      reader ? config.public_send(reader) : nil
    end

    # Execute callback with error isolation
    # @param event [Symbol] Event name (for logging)
    # @param callback [Proc] The callback to execute
    # @param context [CallbackContext] The context to pass
    def execute_safely(event, callback, context)
      return unless callback.respond_to?(:call)

      invoke_callback(callback, context)
    rescue StandardError => e
      # Log but don't re-raise - callbacks should never break organization operations
      log_error("[Organizations] Callback error for #{event}: #{e.class}: #{e.message}")
      log_debug(e.backtrace&.join("\n"))
    end

    # Execute callback and propagate any raised errors.
    # Use this in flows where callbacks are expected to veto the operation.
    def execute_strictly(callback, context)
      return unless callback.respond_to?(:call)

      invoke_callback(callback, context)
    end

    # Call callback while supporting flexible callback arities.
    def invoke_callback(callback, context)
      case callback.arity
      when 0
        callback.call
      when 1, -1, -2
        callback.call(context)
      else
        callback.call(context)
      end
    end

    # Safe logging that works with or without Rails
    def log_error(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.error(message)
      else
        warn(message)
      end
    end

    def log_warn(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      else
        warn(message)
      end
    end

    def log_debug(message)
      return unless message

      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger&.debug?
        Rails.logger.debug(message)
      end
    end
  end
end
