# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.TestRepo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_events_chain

  def installed_extensions, do: ["ash-functions"]

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  # The chain's statements run in the migrations' own transactions; nothing here
  # needs one around every action.
  def prefer_transaction?, do: false
end
