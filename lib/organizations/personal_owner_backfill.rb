# frozen_string_literal: true

module Organizations
  # Links reviewed users to their personal organizations, for installs that
  # created personal workspaces before personal organizations existed.
  # Called through Organizations::Organization.backfill_personal_owners!.
  #
  # The mapping is the only source of truth. A sole member, a name such as
  # "Personal", or the oldest organization never proves that an organization
  # is someone's personal workspace, and a wrong link would later let the
  # account-deletion policy delete a one-person business.
  class PersonalOwnerBackfill
    # assignments - [[user_id, organization_id], ...] written (or to write, in a dry run)
    # unchanged   - [[user_id, organization_id], ...] already linked
    # conflicts   - [{ user_id:, organization_id:, reason: }, ...]
    Report = Struct.new(:assignments, :unchanged, :conflicts, :applied, keyword_init: true) do
      def applied? = applied
    end

    CONFLICT_REASONS = %i[
      organization_not_found
      not_the_owner
      organization_personal_for_another_user
      user_has_another_personal_organization
      organization_mapped_twice
    ].freeze

    def initialize(mapping)
      user_id_type = Organizations.user_class.type_for_attribute(Organizations.user_class.primary_key)
      organization_id_type = Organization.type_for_attribute(Organization.primary_key)
      @pairs = mapping.to_h.map do |user, organization|
        [user_id_type.cast(id_of(user)), organization_id_type.cast(id_of(organization))]
      end
    end

    # @param dry_run [Boolean]
    # @return [Report]
    def run(dry_run: false)
      return analyze if dry_run

      report = nil
      Organization.transaction do
        # Lock the organizations so the checks hold until the write.
        Organization.where(id: @pairs.map(&:last)).order(:id).lock.to_a
        report = analyze
        raise ActiveRecord::Rollback unless report.conflicts.empty?

        report.assignments.each do |user_id, organization_id|
          Organization.find(organization_id).update!(personal_owner_id: user_id)
        end
        report.applied = true
      end
      report
    end

    private

    def analyze
      load_lookups
      report = Report.new(assignments: [], unchanged: [], conflicts: [], applied: false)
      @pairs.each do |user_id, organization_id|
        reason = conflict_for(user_id, organization_id)
        if reason
          report.conflicts << { user_id: user_id, organization_id: organization_id, reason: reason }
        elsif @linked[user_id] == organization_id
          report.unchanged << [user_id, organization_id]
        else
          report.assignments << [user_id, organization_id]
        end
      end
      report
    end

    # One query per rule, for the whole mapping.
    def load_lookups
      organization_ids = @pairs.map(&:last)
      @organizations = Organization.where(id: organization_ids).index_by(&:id)
      @owners = Membership.where(organization_id: @organizations.keys, role: "owner")
        .pluck(:organization_id, :user_id).to_h
      @linked = Organization.personal.where(personal_owner_id: @pairs.map(&:first))
        .pluck(:personal_owner_id, :id).to_h
      @mapped_twice = organization_ids.tally.select { |_, count| count > 1 }.keys
    end

    def conflict_for(user_id, organization_id)
      organization = @organizations[organization_id]
      return :organization_not_found unless organization
      return :organization_mapped_twice if @mapped_twice.include?(organization_id)
      return :not_the_owner unless @owners[organization_id] == user_id
      if organization.personal_owner_id.present? && organization.personal_owner_id != user_id
        return :organization_personal_for_another_user
      end
      return :user_has_another_personal_organization if @linked[user_id] && @linked[user_id] != organization_id

      nil
    end

    def id_of(record)
      record.respond_to?(:id) ? record.id : record
    end
  end
end
