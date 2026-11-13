# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

[
  # `AshEvents.AdvisoryLockKeyGenerator`'s callback types its first argument as
  # `Ash.Resource.t()`, but AshEvents calls it with the changeset
  # (`AshEvents.Events.ActionWrapperHelpers`), which is what the generator reads.
  {"lib/ash_events/chain/lock_key_generator.ex", :callback_arg_type_mismatch}
]
