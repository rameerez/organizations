# frozen_string_literal: true

# SimpleCov configuration (auto-loaded by `require "simplecov"`). It holds
# configuration only: test/test_helper.rb calls SimpleCov.start, as
# SimpleCov 1.x requires.

SimpleCov.configure do
  # Use SimpleFormatter for terminal-only output (no HTML generation)
  formatter SimpleCov::Formatter::SimpleFormatter

  # Report the gem's source (lib/ and app/), unloaded files included
  skip "/test/"
  cover "{lib,app}/**/*.rb"

  # Enable branch coverage for more detailed metrics
  enable_coverage :branch

  # No minimum: running one test file must not fail on coverage. The full
  # suite reports its numbers at exit.

  # Disambiguate parallel test runs
  command_name "Job #{ENV['TEST_ENV_NUMBER']}" if ENV['TEST_ENV_NUMBER']
end

# Print coverage summary to terminal after tests complete
SimpleCov.at_exit do
  SimpleCov.result.format!
  puts "\n" + "=" * 60
  puts "COVERAGE SUMMARY"
  puts "=" * 60
  puts "Line Coverage:   #{SimpleCov.result.covered_percent.round(2)}%"
  puts "Branch Coverage: #{SimpleCov.result.coverage_statistics[:branch]&.percent&.round(2) || 'N/A'}%"
  puts "=" * 60
end
