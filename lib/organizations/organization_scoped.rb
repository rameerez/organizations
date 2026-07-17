# frozen_string_literal: true

module Organizations
  # URL-SCOPED organization resolution — the second addressing mode.
  #
  # The engine's own controllers are SESSION-scoped (one "current"
  # organization per user, workspace/tenant style — the LicenseSeat shape).
  # Overlay-style hosts (community/marketplace apps where users belong to
  # organizations but don't "work inside" one) address organizations BY URL
  # instead: /org/:slug/admin, /teams/:id/settings. Before this concern,
  # such hosts re-derived the same base controller by hand: find org by
  # param → find viewer membership → role-gate → pick a not-found posture.
  #
  # @example A slug-addressed admin portal (the overlay shape)
  #   class Portal::BaseController < ApplicationController
  #     include Organizations::OrganizationScoped
  #
  #     self.organization_param  = :slug
  #     self.organization_finder = ->(param) { Organizations::Organization.find_by(slug: param) }
  #     # 404-never-403: don't disclose which orgs/surfaces exist (default).
  #     require_organization_role :admin
  #   end
  #
  #   class Portal::MembersController < Portal::BaseController
  #     def index
  #       @memberships = current_scoped_organization.memberships.includes(:user)
  #     end
  #   end
  #
  # Knobs (class_attributes, inheritable/overridable per controller):
  #   organization_param    — request param holding the identifier
  #                           (default :organization_id)
  #   organization_finder   — ->(param) { ... } returning the org or nil;
  #                           instance_exec'd on the controller (default
  #                           find_by(id:))
  #   organization_not_found_behavior — :not_found (default) raises
  #                           ActionController::RoutingError so unknown orgs,
  #                           non-members, and under-role members are all
  #                           INDISTINGUISHABLE (no existence oracle);
  #                           :forbidden responds 403 instead (internal
  #                           tools where disclosure is fine).
  #
  # Deliberately DISTINCT from the session helpers (current_organization/
  # current_membership): the two modes coexist — a session-tenant app can
  # still expose a URL-scoped surface — so this concern never touches the
  # session or the model-level current-organization context.
  module OrganizationScoped
    extend ActiveSupport::Concern
    include Organizations::CurrentUserResolution

    included do
      class_attribute :organization_param, default: :organization_id, instance_writer: false
      class_attribute :organization_finder,
                      default: ->(param) { Organizations::Organization.find_by(id: param) },
                      instance_writer: false
      class_attribute :organization_not_found_behavior, default: :not_found, instance_writer: false

      before_action :set_scoped_organization if respond_to?(:before_action)

      if respond_to?(:helper_method)
        helper_method :current_scoped_organization
        helper_method :current_scoped_membership
      end
    end

    class_methods do
      # Gate every action (or only:/except: subsets, forwarded to
      # before_action) behind a minimum role in the scoped organization.
      # Below-role viewers get the configured not-found behavior — same
      # posture as an unknown organization, on purpose.
      #
      # @param role [Symbol] minimum role (uses the gem hierarchy /
      #   custom-role at_least semantics)
      def require_organization_role(role, **options)
        before_action(**options) { require_scoped_organization_role!(role) }
      end
    end

    # The organization resolved from the URL for this request.
    # @return [Organizations::Organization, nil]
    def current_scoped_organization
      @current_scoped_organization
    end

    # The requesting user's membership in the scoped organization.
    # Memoized per request; nil for strangers/signed-out.
    # @return [Organizations::Membership, nil]
    def current_scoped_membership
      return @current_scoped_membership if defined?(@current_scoped_membership)

      user = scoped_organization_viewer
      @current_scoped_membership =
        if user && current_scoped_organization
          current_scoped_organization.memberships.find_by(user_id: user.id)
        end
    end

    private

    # The requesting user via the shared resolution (configured
    # current_user_method, Warden fallback) — own cache ivar so it never
    # collides with ControllerHelpers' memoization when both are included.
    def scoped_organization_viewer
      resolve_organizations_current_user(
        cache_ivar: :@_scoped_organization_viewer,
        prefer_super_for_current_user: false,
        prefer_warden_for_current_user: true
      )
    end

    def set_scoped_organization
      finder = self.class.organization_finder
      @current_scoped_organization = instance_exec(params[self.class.organization_param], &finder)

      scoped_organization_not_found! unless @current_scoped_organization
    end

    def require_scoped_organization_role!(role)
      membership = current_scoped_membership
      return if membership&.is_at_least?(role)

      scoped_organization_not_found!
    end

    def scoped_organization_not_found!
      case self.class.organization_not_found_behavior
      when :forbidden
        head :forbidden
      else
        # RoutingError renders the host's 404 page — chosen over head(:not_found)
        # so the user sees the app's normal not-found experience, and over 403
        # so existence is never disclosed.
        raise ActionController::RoutingError, "Not Found"
      end
    end
  end
end
