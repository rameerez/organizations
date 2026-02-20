# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in organizations.gemspec
gemspec

# slugifiable is specified in gemspec - uses released gem from RubyGems

# Tooling
gem "rake", "~> 13.0"

group :development do
  gem "irb"
  gem "rubocop", "~> 1.0"
  gem "rubocop-minitest", "~> 0.35"
  gem "rubocop-performance", "~> 1.0"
end

group :development, :test do
  gem "appraisal"
  gem "minitest", "~> 6.0"
  gem "minitest-mock"
  gem "rack-test"
  gem "sqlite3", ">= 2.1"
  gem "ostruct"
  gem "simplecov", require: false
  gem "activejob"
  gem "actionmailer"
  gem "globalid"
end
