# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

[
  import_deps: [:ash, :ash_postgres, :ash_events, :spark],
  plugins: [Spark.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}"
  ]
]
