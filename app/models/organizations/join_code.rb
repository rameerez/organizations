# frozen_string_literal: true

# Reloadable entrypoint for Organizations::JoinCode in Rails apps.
# This file lives in app/models so Zeitwerk manages it, making the class
# reload-safe. It delegates to the canonical implementation in lib/.
load File.expand_path("../../../lib/organizations/models/join_code.rb", __dir__)
