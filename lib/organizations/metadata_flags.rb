# frozen_string_literal: true

module Organizations
  # Typed boolean accessors over a json(b) metadata bag, with a DEFAULT for
  # missing keys — the pattern every host grows around the gem's metadata
  # channel ("show this membership on the profile?", "receive digests?").
  #
  # Why not store_accessor: store_accessor gives raw reads — a nil (never
  # set) is indistinguishable from false, so hosts hand-roll the same
  # `value.nil? ? default : Boolean.cast(value)` predicate for every flag
  # (one production host had three identical copies). metadata_flag bakes
  # the default + cast in.
  #
  # Organizations::Organization and Organizations::Membership are already
  # extended with this — call the macro from your extension concern:
  #
  #   ActiveSupport.on_load(:organizations_membership) do
  #     metadata_flag :show_on_profile, default: true
  #     metadata_flag :show_on_leaderboard, default: true
  #   end
  #
  #   membership.show_on_profile?          # => true (unset ⇒ the default)
  #   membership.show_on_profile = false   # writes into metadata
  #   membership.toggle_show_on_profile!   # flip + save!
  #
  # ⚠️ Don't ALSO declare the same key via store_accessor — you'd get two
  # writers with different semantics for one key. Pick one mechanism per key.
  #
  # @example A flag over a different bag column
  #   metadata_flag :beta_features, default: false, column: :settings
  module MetadataFlags
    # @param name [Symbol] flag name (becomes name?, name=, toggle_name!)
    # @param default [Boolean] value when the key is absent from the bag
    # @param column [Symbol] the json(b) attribute holding the bag
    def metadata_flag(name, default:, column: :metadata)
      key = name.to_s

      define_method("#{name}?") do
        bag = public_send(column)
        # Defensive: a non-Hash bag (text column, corrupted value) reads as
        # empty → the default. The WRITER requires a real json(b)/serialized
        # Hash column — see the module docs.
        raw = bag.is_a?(Hash) ? bag[key] : nil
        raw.nil? ? default : ActiveModel::Type::Boolean.new.cast(raw)
      end

      define_method("#{name}=") do |value|
        bag = (public_send(column) || {}).merge(key => value)
        public_send("#{column}=", bag)
      end

      define_method("toggle_#{name}!") do
        public_send("#{name}=", !public_send("#{name}?"))
        save!
        self
      end
    end
  end
end
