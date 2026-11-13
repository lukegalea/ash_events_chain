# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

import Config

# Required by ash >= 3.33. `:codepoints` matches how the database counts string
# length.
config :ash, default_string_length_count: :codepoints

if Mix.env() == :test do
  import_config "test.exs"
end
