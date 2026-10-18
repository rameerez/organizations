# frozen_string_literal: true

# SimpleCov configuration (auto-loaded by `require "simplecov"`). It holds
# configuration only: test/test_helper.rb calls SimpleCov.start, as
# SimpleCov 1.x requires.

SimpleCov.configure do
  # Use SimpleFormatter for terminal-only output (no HTML generation)
  formatter SimpleCov::Formatter::SimpleFormatter

  # Report the gem's source (lib/ and app/), unloaded files included.
  # skip/cover are the SimpleCov 1.x names (Ruby 3.3+); 0.22 on Ruby 3.2
  # knows add_filter/track_files.
  if respond_to?(:cover)
    skip "/test/"
    cover "{lib,app}/**/*.rb"
  else
    add_filter "/test/"
    track_files "{lib,app}/**/*.rb"
  end

  # Enable branch coverage for more detailed metrics
  enable_coverage :branch

  # A floor for the full suite in CI only: running one test file locally
  # must not fail on coverage.
  minimum_coverage line: 78, branch: 72 if ENV["CI"]

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
