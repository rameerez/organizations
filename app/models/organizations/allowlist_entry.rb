# frozen_string_literal: true

# Reloadable entrypoint for Organizations::AllowlistEntry in Rails apps.
# This file lives in app/models so Zeitwerk manages it, making the class
# reload-safe. It delegates to the canonical implementation in lib/.
load File.expand_path("../../../lib/organizations/models/allowlist_entry.rb", __dir__)
