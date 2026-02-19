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
    default from: -> { default_from_address }

    # Invitation email
    # @param invitation [Organizations::Invitation] The invitation to send
    # @return [Mail::Message]
    def invitation_email(invitation)
      @invitation = invitation
      @organization = invitation.organization
      @inviter = invitation.invited_by
      @accept_url = invitation_accept_url(invitation)

      mail(
        to: invitation.email,
        subject: "#{inviter_name} invited you to join #{@organization.name}"
      )
    end

    private

    def inviter_name
      return "The team" unless @inviter

      if @inviter.respond_to?(:name) && @inviter.name.present?
        @inviter.name
      else
        @inviter.email
      end
    end

    def invitation_accept_url(invitation)
      if defined?(Rails) && Rails.application&.routes
        # Try to use the engine routes
        begin
          Organizations::Engine.routes.url_helpers.invitation_url(
            invitation.token,
            host: default_host
          )
        rescue StandardError
          # Fallback to basic URL construction
          "#{default_host}/invitations/#{invitation.token}"
        end
      else
        "/invitations/#{invitation.token}"
      end
    end

    def default_from_address
      if defined?(Rails) && Rails.application&.config&.action_mailer&.default_options
        Rails.application.config.action_mailer.default_options[:from] || "noreply@example.com"
      else
        "noreply@example.com"
      end
    end

    def default_host
      if defined?(Rails) && Rails.application&.config&.action_mailer&.default_url_options
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
