# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.DigestColumnsTest do
  @moduledoc """
  A host whose existing rows were hashed over another column list keeps verifying:
  `AshEvents.Chain.Test.LegacyLog` declares that list with `digest_columns:`.

  The expected hashes here are written out by hand, as the host's own trigger wrote
  them, rather than built from `AshEvents.Chain.SQL`.
  """

  use AshEvents.Chain.DataCase, async: false

  alias AshEvents.Chain
  alias AshEvents.Chain.Info
  alias AshEvents.Chain.Test.{EventLog, LegacyLog, LegacyNote}

  # The host's own canonical form for `legacy_events`, as its trigger computed it.
  @legacy_hash """
  encode(sha256(convert_to(concat_ws('|',
    coalesce(previous_hash, ''),
    coalesce(sequence::text, ''), coalesce(id::text, ''), coalesce(record_id::text, ''),
    coalesce(occurred_at::text, ''), coalesce(resource::text, ''), coalesce(action::text, ''),
    coalesce(action_type::text, ''), coalesce(organization_id::text, ''),
    coalesce(metadata::text, ''), coalesce(data::text, ''), as_of::text
  ), 'UTF8')), 'hex')
  """

  setup do
    %{org: Ash.UUID.generate()}
  end

  defp note!(org, body) do
    LegacyNote
    |> Ash.Changeset.for_create(:create, %{body: body}, tenant: org)
    |> Ash.create!()
  end

  defp matches_legacy_form?(org) do
    TestRepo.query!(
      "SELECT hash = #{@legacy_hash} FROM legacy_events WHERE organization_id = $1::uuid ORDER BY sequence",
      [dump(org)]
    ).rows
    |> Enum.all?(fn [match?] -> match? end)
  end

  test "the spec keeps the declared list and its NULL renderings" do
    assert Info.spec!(LegacyLog).digest_columns == [
             sequence: :empty_if_nil,
             id: :empty_if_nil,
             record_id: :empty_if_nil,
             occurred_at: :empty_if_nil,
             resource: :empty_if_nil,
             action: :empty_if_nil,
             action_type: :empty_if_nil,
             organization_id: :empty_if_nil,
             metadata: :empty_if_nil,
             data: :empty_if_nil,
             as_of: :omit_nil
           ]

    # The default list covers what the log writes, the actor and the partition.
    assert Enum.map(Info.spec!(EventLog).digest_columns, &elem(&1, 0)) == [
             :sequence,
             :id,
             :record_id,
             :version,
             :occurred_at,
             :resource,
             :action,
             :action_type,
             :user_id,
             :organization_id,
             :data,
             :changed_attributes,
             :metadata
           ]
  end

  test "the trigger hashes the declared list, in the host's form", ctx do
    note = note!(ctx.org, "one")
    note |> Ash.Changeset.for_update(:update, %{body: "two"}) |> Ash.update!()

    assert matches_legacy_form?(ctx.org)
    assert %{findings: [], checked: 2} = Chain.verify(LegacyLog, ctx.org)
  end

  # The log keeps AshEvents' default integer id, so this also covers a log whose id
  # is not a UUID.
  #
  # Rows the host's own trigger wrote before it adopted the package: hashed by hand in
  # its form, inserted with the package's trigger off. The package verifies them, and
  # its trigger continues the same chain.
  test "rows hashed before adoption verify, and the chain continues from them", ctx do
    without_triggers(fn ->
      for {as_of, n} <- [{nil, 1}, {~U[2026-01-15 00:00:00.000000Z], 2}] do
        [[id]] =
          TestRepo.query!(
            "INSERT INTO legacy_events (record_id, metadata, occurred_at, resource, action, action_type, " <>
              "organization_id, as_of) VALUES (gen_random_uuid(), $1::jsonb, now(), 'Elixir.Old', " <>
              "'create', 'create', $2::uuid, $3) RETURNING id",
            [%{"organization_id" => ctx.org, "n" => n}, dump(ctx.org), as_of]
          ).rows

        TestRepo.query!(
          """
          UPDATE legacy_events SET
            previous_hash = (SELECT hash FROM legacy_events
                             WHERE organization_id = $2::uuid AND hash IS NOT NULL
                             ORDER BY sequence DESC LIMIT 1)
          WHERE id = $1
          """,
          [id, dump(ctx.org)]
        )

        TestRepo.query!("UPDATE legacy_events SET hash = #{@legacy_hash} WHERE id = $1", [id])
      end
    end)

    note!(ctx.org, "after adoption")

    assert matches_legacy_form?(ctx.org)
    assert %{findings: [], checked: 3} = Chain.verify(LegacyLog, ctx.org)
  end

  test "a column left out of the list is not covered, and one in it is", ctx do
    note!(ctx.org, "one")
    note!(ctx.org, "two")

    without_trigger("legacy_events", "legacy_events_immutable", fn ->
      TestRepo.query!(
        "UPDATE legacy_events SET changed_attributes = '{\"x\": 1}', version = 99 " <>
          "WHERE organization_id = $1::uuid",
        [dump(ctx.org)]
      )
    end)

    assert %{findings: []} = Chain.verify(LegacyLog, ctx.org)

    without_trigger("legacy_events", "legacy_events_immutable", fn ->
      TestRepo.query!(
        "UPDATE legacy_events SET as_of = now() WHERE organization_id = $1::uuid " <>
          "AND sequence = (SELECT min(sequence) FROM legacy_events WHERE organization_id = $1::uuid)",
        [dump(ctx.org)]
      )
    end)

    assert %{findings: [%{problem: :altered}]} = Chain.verify(LegacyLog, ctx.org)
  end

  test "without an archive table, the log refuses every delete, however old", ctx do
    TestRepo.query!(
      "INSERT INTO legacy_events (record_id, metadata, occurred_at, resource, action, action_type) " <>
        "VALUES (gen_random_uuid(), $1::jsonb, now() - interval '500 days', 'Elixir.Old', " <>
        "'create', 'create')",
      [%{"organization_id" => ctx.org}]
    )

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      TestRepo.query!("DELETE FROM legacy_events WHERE organization_id = $1::uuid", [
        dump(ctx.org)
      ])
    end
  end

  defp without_triggers(fun) do
    without_trigger("legacy_events", "legacy_events_chain", fn ->
      without_trigger("legacy_events", "legacy_events_immutable", fun)
    end)
  end
end
