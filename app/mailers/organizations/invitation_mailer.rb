# frozen_string_literal: true

module Organizations
  # Mailer for sending organization invitation emails.
  # Can be customized via Organizations.configuration.invitation_mailer
  #
  # If the goodmail gem is installed, it will automatically use goodmail
  # for beautiful transactional emails.
  #
  # @example Sending an invitation email
  #   InvitationMailer.invitation_email(invitation).deliver_later
  #
  class InvitationMailer < ActionMailer::Base
    # Self-register the gem's app/views so this mailer renders OUTSIDE a full
    # Rails app too (plain-ActiveRecord consumers, this gem's own test env).
    # Under Rails the engine already provides the path — appending a
    # duplicate is harmless (lowest precedence), and host template overrides
    # in the app's own app/views still win.
    append_view_path File.expand_path("../../views", __dir__)

    default from: -> { default_from_address }

    # Invitation email
    # @param invitation [Organizations::Invitation] The invitation to send
    # @return [Mail::Message]
    def invitation_email(invitation)
      @invitation = invitation
      @organization = invitation.organization
      @inviter = invitation.invited_by
      @inviter_name = inviter_name
      @accept_url = invitation_accept_url(invitation)
      # Pre-formatted in the mailer (not the templates) so the strftime
      # fallback lives in exactly one place — see #format_expiry.
      @expires_on = @invitation.expires_at ? format_expiry(@invitation.expires_at) : nil

      mail(
        to: invitation.email,
        subject: Organizations.t(:"mailers.invitation.subject",
                                 inviter: @inviter_name, organization: @organization.name)
      )
    end

    private

    def inviter_name
      return Organizations.t(:"mailers.from_team") unless @inviter

      if @inviter.respond_to?(:name) && @inviter.name.present?
        @inviter.name
      else
        @inviter.email
      end
    end

    # Localize the expiry timestamp when the host has date/time translations
    # (rails-i18n or its own time.formats.long); otherwise fall back to the
    # historical English strftime. Bare i18n (this gem's own test env, plain
    # Ruby consumers) has no time formats, and I18n.l raises in that case —
    # never let a missing date format break invitation delivery.
    def format_expiry(time)
      I18n.l(time, format: :long)
    rescue I18n::MissingTranslationData, I18n::ArgumentError
      time.strftime("%B %d, %Y at %I:%M %p %Z")
    end

    def invitation_accept_url(invitation)
      # ONE implementation for acceptance URLs: Invitation#acceptance_url
      # (mount-point aware via Organizations.engine_mount_path). The previous
      # engine-url_helpers attempt here was mount-UNAWARE — raw engine route
      # helpers don't know where the host mounted the engine, so links broke
      # for any non-root mount.
      invitation.acceptance_url(base_url: full_rails_app? ? default_host : "")
    end

    # ⚠️ `defined?(Rails)` alone is NOT a sufficient guard: several gems
    # (railties fragments, globalid setups, bare test harnesses) define a
    # `Rails` module WITHOUT `.application`, and `Rails.application` then
    # raises NoMethodError instead of returning nil. Found by the first test
    # that ever actually RENDERED these mails. Always pair with respond_to?.
    def full_rails_app?
      defined?(Rails) && Rails.respond_to?(:application) && Rails.application
    end

    def default_from_address
      if full_rails_app? && Rails.application.config.action_mailer&.default_options
        Rails.application.config.action_mailer.default_options[:from] || "noreply@example.com"
      else
        "noreply@example.com"
      end
    end

    def default_host
      if full_rails_app? && Rails.application.config.action_mailer&.default_url_options
        options = Rails.application.config.action_mailer.default_url_options
        protocol = options[:protocol] || "https"
        host = options[:host] || "localhost"
        port = options[:port]

        if port && port != 80 && port != 443
          "#{protocol}://#{host}:#{port}"
        else
          "#{protocol}://#{host}"
        end
      else
        "http://localhost:3000"
      end
    end
  end
end
