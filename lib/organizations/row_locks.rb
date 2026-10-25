# frozen_string_literal: true

module Organizations
  # The one lock order of the gem: the user rows (in id order), then the
  # organization row, then the rows of the organization. A user's deletion
  # locks the user row, then the row of every organization in which it
  # writes. An organization's destroy locks its row before its cascades. A
  # path that writes in an organization takes the same order, or it can
  # deadlock with them on PostgreSQL.
  #
  # The user rows are the ones that the path's writes reference: a row that
  # names a user takes a key share lock on it when it is written, which
  # waits for a deletion of that user. Lock them first, so that the wait
  # comes before the organization row and not after it.
  #
  # @api private
  module RowLocks
    module_function

    # Lock these users' rows, in id order. Nil ids and users that are gone
    # are skipped.
    # @param ids [Array<Object>]
    def lock_users!(*ids)
      ids = ids.flatten.compact.uniq
      return if ids.empty?

      user_class = Organizations.user_class
      key = user_class.primary_key
      user_class.unscoped.where(key => ids).order(key).lock.pluck(key)
    end

    # Lock the organization row. A destroyed organization is skipped: the
    # caller's own row lock then finds its row gone.
    # @param id [Object]
    def lock_organization!(id)
      Organizations::Organization.unscoped.where(id: id).lock.pick(:id)
    end
  end
end
