# frozen_string_literal: true

module Organizations
  # A resource of the host app named by type and id, for grants on records
  # that are not ActiveRecord models (or that you do not want to load):
  #
  #   entity = Organizations::Resource.new("Ledger::Entity", entity_id)
  #   membership.grant!(entity, capabilities: %w[read])
  #   membership.can?(:read, entity)
  Resource = Data.define(:type, :id)
end
