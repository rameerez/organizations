# frozen_string_literal: true

require_relative "lib/organizations/version"

Gem::Specification.new do |spec|
  spec.name = "organizations"
  spec.version = Organizations::VERSION
  spec.authors = ["rameerez"]
  spec.email = ["rubygems@rameerez.com"]

  spec.summary = "Add organizations to any Rails app (with members, roles, and invitations)"
  spec.description = "Add organizations to any Rails app (with members, roles, and invitations). This gem implements the complete User → Membership → Organization pattern with scoped invitations, hierarchical roles (owner, admin, member, viewer), permissions, and organization switching. Turn a User-based app into a multi-tenant, Organization-based B2B SaaS in minutes."
  spec.homepage = "https://github.com/rameerez/organizations"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rameerez/organizations"
  spec.metadata["changelog_uri"] = "https://github.com/rameerez/organizations/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/rameerez/organizations/issues"
  spec.metadata["documentation_uri"] = "https://github.com/rameerez/organizations#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "railties", ">= 7.1.0", "< 9.0"
  spec.add_dependency "activerecord", ">= 7.1.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.1.0", "< 9.0"
  spec.add_dependency "slugifiable", ">= 0.1.0"
end
