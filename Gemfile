# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in organizations.gemspec
gemspec

# slugifiable is specified in gemspec - uses released gem from RubyGems

# Tooling
gem "rake", "~> 13.0"

group :development do
  gem "irb"
  # 1.92+: the `rubocop:disable-next` directive (Style/DirectiveScope)
  gem "rubocop", "~> 1.92"
  gem "rubocop-minitest", "~> 0.39"
  gem "rubocop-performance", "~> 1.26"
end

group :development, :test do
  gem "appraisal"
  gem "minitest", "~> 6.0"
  gem "minitest-mock"
  gem "rack-test"
  gem "sqlite3", ">= 2.1"
  # For the OPTIONAL PostgreSQL leg of the suite (ORGS_TEST_DATABASE_URL) -
  # PG transaction semantics differ where it hurts (aborted-transaction
  # poisoning on unique violations), so CI runs one PG cell too.
  gem "pg"
  gem "ostruct"
  gem "simplecov", ">= 1.3", require: false # skip/cover and SimpleCov.start in the helper
  # Required explicitly for tests since we don't load the full Rails stack
  gem "activejob", ">= 7.1.0", "< 9.0"
  gem "actionmailer", ">= 7.1.0", "< 9.0"
  gem "globalid", ">= 1.0" # ActiveJob dependency for GlobalID::Identification
end
