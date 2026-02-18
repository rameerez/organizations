# frozen_string_literal: true

module Organizations
  class Invitation < ActiveRecord::Base
    self.table_name = "organization_invitations"

    # Associations
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :invited_by, class_name: "User"

    # Validations
    validates :email, presence: true
    validates :token, presence: true, uniqueness: true
    validates :role, presence: true

    # Scopes
    scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }
    scope :expired, -> { where("expires_at <= ?", Time.current) }
    scope :accepted, -> { where.not(accepted_at: nil) }

    # TODO: Implement invitation methods
    # - accept!(user)
    # - expired?
    # - pending?
    # - generate_token
  end
end
