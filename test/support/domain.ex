# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEvents.Chain.Test.User
    resource AshEvents.Chain.Test.Note
    resource AshEvents.Chain.Test.Setting
    resource AshEvents.Chain.Test.EventLog
    resource AshEvents.Chain.Test.ArchivedEvent
    resource AshEvents.Chain.Test.ArchiveRun
    resource AshEvents.Chain.Test.LegacyNote
    resource AshEvents.Chain.Test.LegacyLog
  end
end
