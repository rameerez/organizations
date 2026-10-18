# frozen_string_literal: true

module Organizations
  # Include in a host model whose records can be granted to members:
  #
  #   class Document < ApplicationRecord
  #     include Organizations::Grantable
  #   end
  #
  #   Document.visible_to(membership)                     # what this member may see
  #   Document.visible_to(membership, capability: :edit)  # …and edit
  #   document.organization_grants                         # who has access to it
  #
  # Deleting a record deletes its grants.
  module Grantable
    extend ActiveSupport::Concern

    included do
      has_many :organization_grants, as: :grantable, class_name: "Organizations::Grant", dependent: :destroy

      # Records of this model the membership may see (see Membership#visible).
      # Chain it after your own organization scope.
      scope :visible_to, lambda { |membership, capability: nil|
        membership ? membership.visible(all, capability: capability) : none
      }
    end
  end
end
