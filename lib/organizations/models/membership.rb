# frozen_string_literal: true

module Organizations
  class Membership < ActiveRecord::Base
    self.table_name = "memberships"

    # Associations
    belongs_to :user
    belongs_to :organization, class_name: "Organizations::Organization"

    # Validations
    validates :role, presence: true
    validates :user_id, uniqueness: { scope: :organization_id }

    # Role constants
    ROLES = %i[owner admin member viewer].freeze

    # TODO: Implement membership methods
    # - role hierarchy checks
    # - permission checks
  end
end
