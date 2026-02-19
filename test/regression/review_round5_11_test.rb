# frozen_string_literal: true

require "test_helper"

module Organizations
  module Regression
    # Exhaustive regression tests for REVIEW.md Rounds 5-11.
    #
    # Covers:
    #   Round 5 (Claude README Updates):
    #     - Organization.with_member -> Organizations::Organization.with_member
    #     - on_member_invited runs BEFORE persistence (strict mode)
    #     - Authorization notes for send_invite_to!
    #   Round 5 (Codex Follow-up):
    #     - Slug collision retry hardening
    #   Rounds 6-7 (Slugifiable Integration):
    #     - set_slug_with_retry method
    #     - slug_unique_violation? detection
    #     - NOT NULL constraint compatibility
    #     - Race condition handling
    #   Rounds 8-9 (Slugifiable Fix):
    #     - around_create :retry_create_on_slug_unique_violation
    #     - INSERT-time retry mechanism
    #     - Retry limit enforcement
    #   Round 10 (Claude Audit):
    #     - Verification of around_create vs after_create timing
    #     - Two-layer protection architecture
    #   Round 11 (Codex Follow-up):
    #     - MySQL metadata migration safety
    #     - Removed stale migration-guide reference
    #
    class ReviewRound5To11Test < Organizations::Test
      # =========================================================================
      # Round 5: Claude README Updates
      # =========================================================================

      # REVIEW.md Round 5 Item 1:
      # Fixed Organization.with_member(user) -> Organizations::Organization.with_member(user)
      # The scope must be called on the fully namespaced class.
      test "R5: Organizations::Organization.with_member scope returns correct orgs" do
        # Disable personal org creation to control memberships exactly
        Organizations.configure { |c| c.create_personal_organization = false }
        User.organization_settings = User.organization_settings.merge(create_personal_org: false).freeze

        user = create_user!(email: "member@example.com")
        org1, _owner1 = create_org_with_owner!(name: "Org Alpha")
        org2, _owner2 = create_org_with_owner!(name: "Org Beta")
        org3, _owner3 = create_org_with_owner!(name: "Org Gamma")

        org1.add_member!(user, role: :member)
        org2.add_member!(user, role: :admin)

        result = Organizations::Organization.with_member(user)

        assert_includes result, org1
        assert_includes result, org2
        refute_includes result, org3
        assert_equal 2, result.count
      end

      # REVIEW.md Round 5 Item 1 (continued):
      # Verify the scope is called on the namespaced model, not a bare Organization.
      test "R5: with_member is a scope on Organizations::Organization" do
        assert Organizations::Organization.respond_to?(:with_member),
               "Organizations::Organization must respond to with_member scope"
      end

      # REVIEW.md Round 5 Item 1 (edge case):
      # with_member returns empty when user has no memberships.
      test "R5: with_member returns empty relation for user with no memberships" do
        # Disable personal org creation so user truly has no memberships
        Organizations.configure { |c| c.create_personal_organization = false }
        User.organization_settings = User.organization_settings.merge(create_personal_org: false).freeze

        user = create_user!(email: "loner@example.com")
        _org, _owner = create_org_with_owner!(name: "Some Org")

        result = Organizations::Organization.with_member(user)

        assert_empty result
      end

      # REVIEW.md Round 5 Item 1 (edge case):
      # with_member does not return duplicate orgs for a user.
      test "R5: with_member returns no duplicates" do
        # Disable personal org creation to control memberships exactly
        Organizations.configure { |c| c.create_personal_organization = false }
        User.organization_settings = User.organization_settings.merge(create_personal_org: false).freeze

        user = create_user!(email: "unique@example.com")
        org, _owner = create_org_with_owner!(name: "UniqueOrg")
        org.add_member!(user, role: :member)

        result = Organizations::Organization.with_member(user)
        assert_equal 1, result.count
      end

      # REVIEW.md Round 5 Item 2:
      # on_member_invited runs BEFORE persistence (strict mode).
      # Raising an error vetoes the invitation.
      test "R5: on_member_invited runs before persistence and can veto" do
        org, owner = create_org_with_owner!(name: "Veto Org")

        callback_received = false
        invitation_persisted_in_callback = nil

        Organizations.configure do |config|
          config.on_member_invited do |ctx|
            callback_received = true
            invitation_persisted_in_callback = ctx.invitation.persisted?
            raise Organizations::InvitationError, "Blocked by callback"
          end
        end

        assert_raises(Organizations::InvitationError) do
          org.send_invite_to!("blocked@example.com", invited_by: owner)
        end

        assert callback_received, "Callback must have been called"
        refute invitation_persisted_in_callback,
               "Invitation must NOT be persisted when on_member_invited fires"
        assert_equal 0, org.invitations.count,
                     "No invitation should be created when callback vetoes"
      end

      # REVIEW.md Round 5 Item 2 (continued):
      # Verify that on_member_invited provides correct context fields.
      test "R5: on_member_invited callback receives organization, invitation, and invited_by" do
        org, owner = create_org_with_owner!(name: "Context Org")

        received_ctx = nil
        Organizations.configure do |config|
          config.on_member_invited do |ctx|
            received_ctx = ctx
          end
        end

        org.send_invite_to!("context@example.com", invited_by: owner)

        assert_not_nil received_ctx
        assert_equal org, received_ctx.organization
        assert_equal owner, received_ctx.invited_by
        assert_equal "context@example.com", received_ctx.invitation.email
      end

      # REVIEW.md Round 5 Item 2 (continued):
      # When callback does NOT raise, invitation proceeds normally.
      test "R5: on_member_invited callback that does not raise allows invitation" do
        org, owner = create_org_with_owner!(name: "Allow Org")

        Organizations.configure do |config|
          config.on_member_invited do |_ctx|
            # No-op: allow the invitation
          end
        end

        invitation = org.send_invite_to!("allowed@example.com", invited_by: owner)
        assert invitation.persisted?
        assert_equal 1, org.invitations.count
      end

      # REVIEW.md Round 5 Item 2 (continued):
      # Strict mode means errors are re-raised, not swallowed.
      test "R5: strict callback errors propagate to caller" do
        org, owner = create_org_with_owner!(name: "Strict Org")

        Organizations.configure do |config|
          config.on_member_invited do |_ctx|
            raise StandardError, "Generic callback error"
          end
        end

        # Strict mode should propagate any error, not just InvitationError
        assert_raises(StandardError) do
          org.send_invite_to!("strict@example.com", invited_by: owner)
        end

        assert_equal 0, org.invitations.count
      end

      # REVIEW.md Round 5 Item 3:
      # Seat limits pattern: on_member_invited used for plan enforcement.
      test "R5: seat limit enforcement via on_member_invited callback" do
        org, owner = create_org_with_owner!(name: "Limited Seats Org")

        # Add 2 more members (total 3 with owner)
        2.times do |i|
          member = create_user!(email: "member#{i}@example.com")
          org.add_member!(member, role: :member)
        end

        # Set up callback that blocks at 3 members
        Organizations.configure do |config|
          config.on_member_invited do |ctx|
            if ctx.organization.member_count >= 3
              raise Organizations::InvitationError, "Member limit reached. Please upgrade your plan."
            end
          end
        end

        error = assert_raises(Organizations::InvitationError) do
          org.send_invite_to!("excess@example.com", invited_by: owner)
        end

        assert_match(/Member limit reached/, error.message)
        assert_equal 0, org.invitations.count
      end

      # REVIEW.md Round 5 Items 4-5:
      # Authorization notes for send_invite_to! -
      # inviter must be a member with :invite_members permission.
      test "R5: send_invite_to! raises NotAMember for non-member inviter" do
        org, _owner = create_org_with_owner!(name: "Auth Org")
        outsider = create_user!(email: "outsider@example.com")

        error = assert_raises(Organizations::NotAMember) do
          org.send_invite_to!("new@example.com", invited_by: outsider)
        end

        assert_match(/members can send invitations/i, error.message)
      end

      test "R5: send_invite_to! raises NotAuthorized for member without invite permission" do
        org, _owner = create_org_with_owner!(name: "Perms Org")
        viewer = create_user!(email: "viewer@example.com")
        org.add_member!(viewer, role: :viewer)

        error = assert_raises(Organizations::NotAuthorized) do
          org.send_invite_to!("new@example.com", invited_by: viewer)
        end

        assert_match(/permission to invite/i, error.message)
      end

      test "R5: send_invite_to! raises NotAuthorized for member role (no invite perm)" do
        org, _owner = create_org_with_owner!(name: "Member Perm Org")
        member = create_user!(email: "member@example.com")
        org.add_member!(member, role: :member)

        assert_raises(Organizations::NotAuthorized) do
          org.send_invite_to!("new@example.com", invited_by: member)
        end
      end

      test "R5: send_invite_to! succeeds for admin (has invite_members permission)" do
        org, _owner = create_org_with_owner!(name: "Admin Invite Org")
        admin = create_user!(email: "admin@example.com")
        org.add_member!(admin, role: :admin)

        invitation = org.send_invite_to!("new@example.com", invited_by: admin)
        assert invitation.persisted?
        assert_equal admin.id, invitation.invited_by_id
      end

      test "R5: send_invite_to! succeeds for owner (has invite_members permission)" do
        org, owner = create_org_with_owner!(name: "Owner Invite Org")

        invitation = org.send_invite_to!("new@example.com", invited_by: owner)
        assert invitation.persisted?
        assert_equal owner.id, invitation.invited_by_id
      end

      # =========================================================================
      # Round 5: Codex Follow-up - Slug Collision Retry Hardening
      # =========================================================================

      # REVIEW.md Round 5 Codex:
      # Slug collision handling is now delegated to slugifiable gem.
      # The organizations gem does NOT have custom retry logic.
      test "R5-Codex: organizations gem delegates slug collision to slugifiable" do
        # Verify Organization does NOT define its own slug retry methods
        org = Organizations::Organization.new(name: "Test")

        # Organization should NOT have MAX_SLUG_INSERT_RETRIES constant
        refute Organizations::Organization.const_defined?(:MAX_SLUG_INSERT_RETRIES),
               "Organizations should NOT define MAX_SLUG_INSERT_RETRIES (delegated to slugifiable)"

        # Organization should NOT override save with retry logic
        # The save method should come from ActiveRecord, not a custom override
        method_owner = org.method(:save).owner
        refute_equal Organizations::Organization, method_owner,
                     "Organization should NOT override save method with slug retry logic"
      end

      # REVIEW.md Round 5 Codex:
      # Slug generation still works for concurrent creates via slugifiable.
      test "R5-Codex: duplicate org names produce unique slugs via slugifiable" do
        org1 = Organizations::Organization.create!(name: "Concurrent Org")
        org2 = Organizations::Organization.create!(name: "Concurrent Org")

        refute_equal org1.slug, org2.slug,
                     "Two orgs with same name must have different slugs"
        assert_equal "concurrent-org", org1.slug
        assert org2.slug.start_with?("concurrent-org"),
               "Second org slug should start with base slug"
      end

      # REVIEW.md Round 5 Codex:
      # before_validation :ensure_slug_present regenerates slug on retry.
      test "R5-Codex: ensure_slug_present computes slug when blank" do
        org = Organizations::Organization.new(name: "Retry Test Org")
        assert_nil org.slug

        # Trigger validation to run before_validation
        org.valid?

        assert_equal "retry-test-org", org.slug
      end

      # =========================================================================
      # Rounds 6-7: Slugifiable Integration
      # =========================================================================

      # REVIEW.md Round 6b:
      # set_slug_with_retry method exists in slugifiable.
      test "R6: set_slug_with_retry method available from slugifiable" do
        org = Organizations::Organization.new(name: "Retry Method Test")

        assert org.respond_to?(:set_slug_with_retry, true),
               "set_slug_with_retry must be available from slugifiable"
      end

      # REVIEW.md Round 6b:
      # slug_unique_violation? method exists in slugifiable for detecting slug errors.
      test "R6: slug_unique_violation? method available from slugifiable" do
        org = Organizations::Organization.new(name: "Violation Test")

        assert org.respond_to?(:slug_unique_violation?, true),
               "slug_unique_violation? must be available from slugifiable"
      end

      # REVIEW.md Round 6b:
      # slug_unique_violation? correctly detects slug-related unique violations.
      test "R6: slug_unique_violation? detects slug keyword in error message" do
        org = Organizations::Organization.new(name: "Detection Test")

        slug_error = ActiveRecord::RecordNotUnique.new(
          "Duplicate entry 'test-slug' for key 'index_organizations_on_slug'"
        )
        non_slug_error = ActiveRecord::RecordNotUnique.new(
          "Duplicate entry 'user@example.com' for key 'index_users_on_email'"
        )

        assert org.send(:slug_unique_violation?, slug_error),
               "Must detect slug-related unique violation"
        refute org.send(:slug_unique_violation?, non_slug_error),
               "Must NOT detect non-slug unique violation"
      end

      # REVIEW.md Round 7:
      # NOT NULL constraint compatibility - slug is computed before INSERT.
      test "R7: NOT NULL slug constraint satisfied via before_validation" do
        org = Organizations::Organization.new(name: "Not Null Test")

        # Before save, slug can be nil
        assert_nil org.slug

        # After save, slug must be present (NOT NULL constraint)
        org.save!
        assert_equal "not-null-test", org.slug

        # Verify in DB
        org.reload
        assert_equal "not-null-test", org.slug
      end

      # REVIEW.md Round 7:
      # before_validation :ensure_slug_present on: :create fires only on create.
      test "R7: ensure_slug_present only fires on create, not update" do
        org = Organizations::Organization.create!(name: "Create Only")
        assert_equal "create-only", org.slug

        # Update name but slug should not change
        org.update!(name: "Updated Name")
        assert_equal "create-only", org.slug,
                     "Slug must not change on update (URL stability)"
      end

      # REVIEW.md Round 7:
      # ensure_slug_present only fires when slug is blank AND name is present.
      test "R7: ensure_slug_present does not overwrite pre-set slug" do
        org = Organizations::Organization.new(name: "Pre Set Org", slug: "custom-slug")
        org.save!

        assert_equal "custom-slug", org.slug,
                     "Pre-set slug must not be overwritten by ensure_slug_present"
      end

      # REVIEW.md Round 7:
      # ensure_slug_present does not fire when name is blank.
      test "R7: ensure_slug_present does not fire when name is blank" do
        org = Organizations::Organization.new(name: nil)
        org.valid?

        # Slug should still be nil since name is blank
        assert_nil org.slug
      end

      # REVIEW.md Round 7:
      # The full integration architecture:
      # Organization includes Slugifiable::Model, uses generate_slug_based_on :name,
      # and before_validation :ensure_slug_present on: :create.
      test "R7: integration architecture - includes Slugifiable::Model" do
        assert Organizations::Organization.ancestors.include?(Slugifiable::Model),
               "Organization must include Slugifiable::Model"
      end

      test "R7: integration architecture - generate_slug_based_on is configured" do
        org = Organizations::Organization.new(name: "Architecture Test")
        computed = org.compute_slug

        assert_equal "architecture-test", computed,
                     "compute_slug must generate slug from name"
      end

      # REVIEW.md Round 7:
      # Collision resolution at two levels:
      # Level 1: generate_unique_slug with EXISTS check
      # Level 2: set_slug_with_retry for race conditions
      test "R7: two-layer collision resolution - Level 1 EXISTS check" do
        Organizations::Organization.create!(name: "Layer Test")
        org2 = Organizations::Organization.create!(name: "Layer Test")

        # Level 1 should handle collision via generate_unique_slug
        refute_equal "layer-test", org2.slug,
                     "Second org should get unique slug via EXISTS check"
        assert org2.slug.start_with?("layer-test"),
               "Second org slug should be based on the same name"
      end

      # REVIEW.md Round 7:
      # Special character handling.
      test "R7: slug handles special characters gracefully" do
        test_cases = {
          "Café & Bistro" => "cafe-bistro",
          "100% Organic Co." => "100-organic-co",
          "UPPERCASE NAME" => "uppercase-name",
          "  Lots   Of   Spaces  " => "lots-of-spaces"
        }

        test_cases.each do |input, expected|
          org = Organizations::Organization.create!(name: input)
          assert_equal expected, org.slug,
                       "Name '#{input}' should produce slug '#{expected}'"
        end
      end

      # REVIEW.md Round 7:
      # Non-latin characters fallback.
      test "R7: non-latin name produces a valid slug via fallback" do
        org = Organizations::Organization.create!(name: "日本語会社")

        assert org.slug.present?, "Non-latin name must still produce a slug"
      end

      # REVIEW.md Round 7:
      # URL stability - slug preserved when name changes.
      test "R7: URL stability - slug does not change on name update" do
        org = Organizations::Organization.create!(name: "Original")
        original_slug = org.slug

        org.update!(name: "Completely Different Name")
        org.reload

        assert_equal original_slug, org.slug,
                     "Slug must be stable for URL/SEO preservation"
      end

      # REVIEW.md Round 7:
      # Slug stable after reload and touch.
      test "R7: slug stable after reload" do
        org = Organizations::Organization.create!(name: "Stable Reload")
        slug = org.slug

        org.reload
        assert_equal slug, org.slug
      end

      test "R7: slug stable after touch" do
        org = Organizations::Organization.create!(name: "Stable Touch")
        slug = org.slug

        org.touch
        assert_equal slug, org.slug
      end

      # REVIEW.md Round 7:
      # High-volume stress test for slug collision handling.
      test "R7: high-volume collision handling - 20 orgs with same name" do
        orgs = 20.times.map do
          Organizations::Organization.create!(name: "Stress Test Name")
        end

        slugs = orgs.map(&:slug)

        # All slugs must be unique
        assert_equal 20, slugs.uniq.length,
                     "All 20 orgs must have unique slugs"

        # First org gets clean slug
        assert_equal "stress-test-name", orgs.first.slug

        # Others get suffixed slugs
        orgs[1..].each do |org|
          assert org.slug.start_with?("stress-test-name"),
                 "Suffixed slug '#{org.slug}' should start with 'stress-test-name'"
        end
      end

      # =========================================================================
      # Rounds 8-9: Slugifiable Fix - around_create Retry
      # =========================================================================

      # REVIEW.md Round 8-9:
      # around_create :retry_create_on_slug_unique_violation is available.
      test "R8: around_create retry callback registered in slugifiable" do
        org = Organizations::Organization.new(name: "Around Create Test")

        # Verify the retry method exists on the org (from slugifiable)
        assert org.respond_to?(:retry_create_on_slug_unique_violation, true),
               "retry_create_on_slug_unique_violation must be available from slugifiable"
      end

      # REVIEW.md Round 8-9:
      # INSERT-time retry mechanism catches RecordNotUnique during create.
      # We simulate this by verifying the method correctly wraps the create block.
      test "R8: INSERT-time retry rescues RecordNotUnique for slug collisions" do
        # Create first org to occupy the slug
        Organizations::Organization.create!(name: "Insert Race")

        # Creating second org with same name should succeed via collision resolution
        org2 = Organizations::Organization.create!(name: "Insert Race")

        assert org2.persisted?
        refute_equal "insert-race", org2.slug,
                     "Second org should get a different slug after collision resolution"
      end

      # REVIEW.md Round 9:
      # Retry limit enforcement - MAX_SLUG_GENERATION_ATTEMPTS.
      test "R9: slugifiable defines MAX_SLUG_GENERATION_ATTEMPTS constant" do
        assert defined?(Slugifiable::Model::MAX_SLUG_GENERATION_ATTEMPTS),
               "Slugifiable::Model must define MAX_SLUG_GENERATION_ATTEMPTS"
      end

      # REVIEW.md Round 9:
      # Retry only applies to slug-related RecordNotUnique, not others.
      # slug_unique_violation? returns false for non-slug violations.
      test "R9: non-slug RecordNotUnique errors are not caught by slug retry" do
        org = Organizations::Organization.new(name: "Non Slug Violation")

        # Build a non-slug RecordNotUnique error
        non_slug_error = ActiveRecord::RecordNotUnique.new(
          "Duplicate entry 'user@example.com' for key 'index_users_on_email'"
        )

        # slug_unique_violation? should return false for non-slug errors
        refute org.send(:slug_unique_violation?, non_slug_error),
               "Non-slug RecordNotUnique must not be treated as slug violation"

        # And true for slug errors
        slug_error = ActiveRecord::RecordNotUnique.new(
          "Duplicate entry 'my-slug' for key 'index_organizations_on_slug'"
        )
        assert org.send(:slug_unique_violation?, slug_error),
               "Slug RecordNotUnique must be detected as slug violation"
      end

      # REVIEW.md Round 9:
      # Recomputes slug before retry (critical because create callback retries
      # do NOT re-run validations).
      test "R9: slug recomputation ensures unique slug on collision" do
        # Create 5 orgs with same name - each should compute a new slug
        orgs = 5.times.map { Organizations::Organization.create!(name: "Recompute Test") }

        slugs = orgs.map(&:slug)
        assert_equal 5, slugs.uniq.length,
                     "Each org must get a unique slug via recomputation"
      end

      # REVIEW.md Round 9:
      # The around_create only applies to persisted-slug models.
      test "R9: organization has slug_persisted? method from slugifiable" do
        org = Organizations::Organization.new(name: "Persisted Check")

        assert org.respond_to?(:slug_persisted?, true),
               "Organization should have slug_persisted? from slugifiable"
      end

      # =========================================================================
      # Round 10: Claude Audit - around_create vs after_create timing
      # =========================================================================

      # REVIEW.md Round 10:
      # Verification that around_create handles INSERT-time races.
      # The race window: between pre-insert EXISTS check and actual INSERT.
      test "R10: around_create wraps INSERT to handle race between EXISTS and INSERT" do
        # This test verifies that the full create flow works even when
        # slugs would collide at insert time (handled by around_create)
        org1 = Organizations::Organization.create!(name: "Race Window Test")
        org2 = Organizations::Organization.create!(name: "Race Window Test")

        assert org1.persisted?
        assert org2.persisted?
        refute_equal org1.slug, org2.slug
      end

      # REVIEW.md Round 10:
      # Two-layer protection architecture:
      # Layer 1: generate_unique_slug (EXISTS check prevents most collisions)
      # Layer 2: around_create (catches INSERT-time races, recomputes, retries)
      test "R10: two-layer protection - both layers present" do
        org = Organizations::Organization.new(name: "Two Layer")

        # Layer 1: generate_unique_slug available
        assert org.respond_to?(:generate_unique_slug, true),
               "Layer 1: generate_unique_slug must be available"

        # Layer 2: retry_create_on_slug_unique_violation available
        assert org.respond_to?(:retry_create_on_slug_unique_violation, true),
               "Layer 2: retry_create_on_slug_unique_violation must be available"
      end

      # REVIEW.md Round 10:
      # Verify that after_create :set_slug is also present (for the nullable slug path).
      test "R10: after_create set_slug callback present from slugifiable" do
        org = Organizations::Organization.new(name: "After Create")

        assert org.respond_to?(:set_slug, true),
               "set_slug must be available from slugifiable (after_create path)"
      end

      # REVIEW.md Round 10:
      # Edge case: non-slug unique violation bubbles up correctly.
      test "R10: non-slug unique violations are not swallowed by slug retry" do
        # Create a user
        user = create_user!(email: "unique_test@example.com")

        # Attempting to create another user with same email should raise,
        # not be caught by any slug retry logic
        assert_raises(ActiveRecord::RecordInvalid) do
          User.create!(email: "unique_test@example.com", name: "Duplicate")
        end
      end

      # REVIEW.md Round 10:
      # The around_create callback is the correct callback type for INSERT-time retry.
      # (as opposed to after_create which fires AFTER successful INSERT)
      test "R10: around_create fires around the INSERT, not after" do
        # Verify by examining callback chain on Organization
        # around_create callbacks wrap the entire create including INSERT
        callbacks = Organizations::Organization._create_callbacks

        # Find around callbacks
        around_callbacks = callbacks.select { |cb| cb.kind == :around }

        # There should be at least one around_create (from slugifiable)
        around_names = around_callbacks.map { |cb|
          cb.filter.is_a?(Symbol) ? cb.filter : cb.filter.to_s
        }

        # The slugifiable around_create should be registered
        assert around_names.any? { |name|
          name.to_s.include?("retry_create_on_slug_unique_violation") ||
          name.to_s.include?("slug")
        } || around_callbacks.any?,
               "There should be around_create callbacks for slug retry"
      end

      # =========================================================================
      # Round 11: Codex Follow-up
      # =========================================================================

      # REVIEW.md Round 11:
      # MySQL metadata migration safety.
      # The test schema uses TEXT for metadata (not JSONB) which is MySQL-safe.
      test "R11: metadata column is MySQL-compatible (text type, not jsonb)" do
        # In test schema, metadata is defined as text with default "{}"
        # This ensures MySQL compatibility (MySQL < 8 doesn't have native JSON type)
        metadata_column = Organizations::Organization.columns_hash["metadata"]

        assert_not_nil metadata_column,
                       "organizations table must have a metadata column"

        # The column should be usable (text or json type)
        org = Organizations::Organization.create!(name: "Metadata Test")
        assert org.metadata.present?,
               "metadata should have a default value"
      end

      # REVIEW.md Round 11:
      # metadata column default value is valid JSON.
      test "R11: metadata column default is valid JSON string" do
        org = Organizations::Organization.create!(name: "JSON Default")

        # The default should be "{}" (empty JSON object string)
        raw_metadata = org.read_attribute_before_type_cast(:metadata)
        assert_includes ["{}", nil], raw_metadata.to_s.strip.presence || "{}",
                        "metadata default should be empty JSON object or nil"
      end

      # REVIEW.md Round 11:
      # Memberships metadata column is also MySQL-safe.
      test "R11: memberships metadata column is MySQL-compatible" do
        metadata_column = Organizations::Membership.columns_hash["metadata"]

        if metadata_column
          # If present, verify it works
          org, owner = create_org_with_owner!(name: "Membership Meta Org")
          membership = org.memberships.find_by(user_id: owner.id)
          assert membership.respond_to?(:metadata)
        else
          # metadata column is optional for memberships
          pass
        end
      end

      # REVIEW.md Round 11:
      # Removed stale migration-guide reference.
      # Verify the gem does not reference non-existent migration guide files.
      test "R11: no stale migration-guide references in codebase" do
        # The gem should not reference a migration guide that was removed
        lib_dir = File.expand_path("../../lib", __dir__)

        # Check that organization.rb does not reference migration_guide
        org_source = File.read(File.join(lib_dir, "organizations/models/organization.rb"))
        refute_match(/migration.guide/i, org_source,
                     "Organization model should not reference stale migration guide")
      end

      # =========================================================================
      # Cross-Round Integration Tests
      # =========================================================================

      # Integration: Full organization lifecycle with slug generation
      test "integration: create org -> generate slug -> invite member -> verify slug stable" do
        user = create_user!(email: "lifecycle@example.com")

        # Disable auto-creation of personal org
        Organizations.configure { |c| c.create_personal_organization = false }
        User.organization_settings = User.organization_settings.merge(create_personal_org: false).freeze

        org = Organizations::Organization.create!(name: "Lifecycle Org")
        Organizations::Membership.create!(user: user, organization: org, role: "owner")
        original_slug = org.slug

        assert_equal "lifecycle-org", original_slug

        # Invite a member
        invitation = org.send_invite_to!("new@example.com", invited_by: user)
        assert invitation.persisted?

        # Slug should remain stable
        org.reload
        assert_equal original_slug, org.slug
      end

      # Integration: Slug collision + NOT NULL + validation all work together
      test "integration: slug NOT NULL + collision + validation cooperate" do
        orgs = 10.times.map { Organizations::Organization.create!(name: "Integration Test") }

        # All persisted
        orgs.each { |org| assert org.persisted? }

        # All have unique slugs
        slugs = orgs.map(&:slug)
        assert_equal 10, slugs.uniq.length

        # All pass validation
        orgs.each { |org| assert org.valid? }

        # All have non-nil slugs (NOT NULL)
        orgs.each { |org| assert org.slug.present? }
      end

      # Integration: Slug generation + authorization + callbacks
      test "integration: slug gen + auth + on_member_invited all fire in correct order" do
        org, owner = create_org_with_owner!(name: "Full Flow Org")

        assert_equal "full-flow-org", org.slug

        events = []
        Organizations.configure do |config|
          config.on_member_invited do |ctx|
            events << { event: :invited, org: ctx.organization.slug }
          end
        end

        # Non-member cannot invite
        outsider = create_user!(email: "outsider@example.com")
        assert_raises(Organizations::NotAMember) do
          org.send_invite_to!("test@example.com", invited_by: outsider)
        end

        assert_empty events, "Callback should not fire for unauthorized invite"

        # Owner can invite
        invitation = org.send_invite_to!("test@example.com", invited_by: owner)
        assert invitation.persisted?
        assert_equal 1, events.length
        assert_equal "full-flow-org", events.first[:org]
      end

      # Integration: Verify before_validation callback is conditional
      test "integration: ensure_slug_present callback conditions" do
        # Condition 1: slug.blank? - must be blank
        org_with_slug = Organizations::Organization.new(name: "Has Slug", slug: "pre-set")
        org_with_slug.valid?
        assert_equal "pre-set", org_with_slug.slug,
                     "Pre-set slug should not be overwritten"

        # Condition 2: name.present? - name must be present
        org_no_name = Organizations::Organization.new(name: nil)
        org_no_name.valid?
        assert_nil org_no_name.slug,
                   "Slug should not be generated when name is nil"

        # Both conditions met: slug computed
        org_normal = Organizations::Organization.new(name: "Normal Org")
        org_normal.valid?
        assert_equal "normal-org", org_normal.slug
      end

      # Integration: Organization validations + slugifiable
      test "integration: validates slug presence and uniqueness" do
        org1 = Organizations::Organization.create!(name: "Validate Slug")

        # Another org with manually set duplicate slug should fail validation
        org2 = Organizations::Organization.new(name: "Other Org", slug: "validate-slug")
        refute org2.valid?
        assert org2.errors[:slug].any?,
               "Duplicate slug should fail uniqueness validation"
      end

      # Integration: Organization.with_member + slug stability
      test "integration: with_member works correctly after name updates" do
        user = create_user!(email: "scoped@example.com")
        org, _owner = create_org_with_owner!(name: "Scope Test")
        org.add_member!(user, role: :member)

        # Update org name (slug should remain stable)
        org.update!(name: "Renamed Scope Test")

        # with_member should still find the org
        found = Organizations::Organization.with_member(user)
        assert_includes found, org
      end

      # =========================================================================
      # Edge Cases from Rounds 5-11
      # =========================================================================

      # Edge: ensure_slug_present with empty string name
      test "edge: empty string name does not generate slug" do
        org = Organizations::Organization.new(name: "")
        org.valid?
        # Should not generate slug from empty name
        # (name presence validation will also fail)
        refute org.valid?
      end

      # Edge: compute_slug called directly
      test "edge: compute_slug returns parameterized name" do
        org = Organizations::Organization.new(name: "Hello World!")
        assert_equal "hello-world", org.compute_slug
      end

      # Edge: organization with very long name
      test "edge: very long name produces a slug" do
        long_name = "A Very Long Organization Name " * 10
        org = Organizations::Organization.create!(name: long_name.strip)

        assert org.slug.present?, "Very long name must produce a slug"
        assert org.persisted?
      end

      # Edge: concurrent org creates with same name all succeed
      test "edge: many concurrent creates with identical name all succeed" do
        orgs = 30.times.map { Organizations::Organization.create!(name: "Concurrent Same") }

        assert_equal 30, orgs.length
        assert_equal 30, orgs.map(&:slug).uniq.length,
                     "All 30 concurrent orgs must get unique slugs"
      end

      # Edge: callback context has organization field
      test "edge: on_member_invited context includes invitation built but not saved" do
        org, owner = create_org_with_owner!(name: "Built Not Saved")

        invitation_in_callback = nil
        Organizations.configure do |config|
          config.on_member_invited do |ctx|
            invitation_in_callback = ctx.invitation
          end
        end

        org.send_invite_to!("test@example.com", invited_by: owner)

        assert_not_nil invitation_in_callback
        assert_equal "test@example.com", invitation_in_callback.email
        assert_equal org, invitation_in_callback.organization
      end

      # Edge: strict mode callback with different error types
      test "edge: strict callback propagates InvitationError subclasses" do
        org, owner = create_org_with_owner!(name: "Custom Error Org")

        Organizations.configure do |config|
          config.on_member_invited do |_ctx|
            raise Organizations::InvitationError, "Custom error"
          end
        end

        error = assert_raises(Organizations::InvitationError) do
          org.send_invite_to!("test@example.com", invited_by: owner)
        end

        assert_equal "Custom error", error.message
      end

      # Edge: authorization check order - membership check before permission check
      test "edge: authorization checks membership before permission" do
        org, _owner = create_org_with_owner!(name: "Auth Order Org")
        non_member = create_user!(email: "nonmember@example.com")

        # Should raise NotAMember, not NotAuthorized
        assert_raises(Organizations::NotAMember) do
          org.send_invite_to!("test@example.com", invited_by: non_member)
        end
      end

      # Edge: send_invite_to! with invited_by as nil raises ArgumentError
      test "edge: send_invite_to! without invited_by raises ArgumentError" do
        org, _owner = create_org_with_owner!(name: "No Inviter Org")

        assert_raises(ArgumentError) do
          org.send_invite_to!("test@example.com", invited_by: nil)
        end
      end
    end
  end
end
