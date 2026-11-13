# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Test.RetentionWorker do
  @moduledoc "The host's retention job."
  use AshEvents.Chain.RetentionWorker,
    log: AshEvents.Chain.Test.EventLog,
    otp_app: :ash_events_chain,
    actor: {AshEvents.Chain.Test.Actors, :retention, []}
end
