# frozen_string_literal: true

require "test_helper"

# config.user_class: hosts whose account model is NOT named `User`.
#
# The real behavioral proof runs in a SUBPROCESS (test/isolated/
# custom_user_class_boot.rb) because user_class is read when each model class
# body executes — a boot-order property that cannot be exercised inside this
# already-booted suite without re-`load`ing live classes (which would
# duplicate validations/callbacks). See the boot script's header.
class UserClassTest < ActiveSupport::TestCase
  def teardown
    Organizations.reset_configuration!
  end

  test "defaults to User" do
    assert_equal "User", Organizations.user_class_name
    assert_equal User, Organizations.user_class
  end

  test "validates user_class is a non-empty String" do
    error = assert_raises(Organizations::ConfigurationError) do
      Organizations.configure { |config| config.user_class = :User }
    end
    assert_match(/user_class must be a non-empty String/, error.message)

    assert_raises(Organizations::ConfigurationError) do
      Organizations.configure { |config| config.user_class = "" }
    end
  end

  test "a custom user class wires every association and the full join flow (isolated boot)" do
    script = File.expand_path("isolated/custom_user_class_boot.rb", __dir__)
    output = IO.popen([RbConfig.ruby, script], err: %i[child out], &:read)

    assert $?.success?, "isolated boot failed:\n#{output}"
    assert_includes output, "OK"
  end
end
