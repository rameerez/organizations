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
  # The user guard is a key share lock (FOR KEY SHARE on PostgreSQL). It
  # conflicts with the deletion's FOR UPDATE, which is its purpose, and with
  # nothing else: an ordinary update of the user and the foreign key check
  # of another writer pass. A FOR UPDATE guard would block those writers,
  # and a writer that holds a row this path waits for would then close a
  # cycle (a reject! that sets decided_by_id, a grant that names its
  # granter).
  #
  # Inside a host transaction the order holds only when the host's earlier
  # locks in that transaction keep it too.
  #
  # @api private
  module RowLocks
    module_function

    # Take the key share guard on these users' rows, in id order. Nil ids
    # and users that are gone are skipped.
    # @param ids [Array<Object>]
    def lock_users!(*ids)
      ids = ids.flatten.compact.uniq
      return if ids.empty?

      user_class = Organizations.user_class
      key = user_class.primary_key
      user_class.unscoped.where(key => ids).order(key).lock(key_share_clause(user_class.connection)).pluck(key)
    end

    # PostgreSQL has a lock that only a delete or a key change conflicts
    # with. MySQL has a shared lock. SQLite has no row locks: Rails drops
    # the clause there.
    def key_share_clause(connection)
      adapter = connection.adapter_name.downcase
      return "FOR KEY SHARE" if adapter.include?("postg")
      return "LOCK IN SHARE MODE" if adapter.include?("mysql") || adapter.include?("trilogy")

      true
    end

    # Lock the organization row. A destroyed organization is skipped: the
    # caller's own row lock then finds its row gone.
    # @param id [Object]
    def lock_organization!(id)
      Organizations::Organization.unscoped.where(id: id).lock.pick(:id)
    end
  end
end
