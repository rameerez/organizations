# frozen_string_literal: true

module Organizations
  class Organization < ActiveRecord::Base
    self.table_name = "organizations"

    # Associations
    has_many :memberships, class_name: "Organizations::Membership", dependent: :destroy
    has_many :users, through: :memberships
    has_many :invitations, class_name: "Organizations::Invitation", dependent: :destroy

    # Validations
    validates :name, presence: true
    validates :slug, presence: true, uniqueness: true

    # TODO: Implement organization methods
    # - owner
    # - admins
    # - members
    # - has_member?(user)
    # - add_member!(user, role:)
    # - remove_member!(user)
    # - pending_invitations
  end
end
