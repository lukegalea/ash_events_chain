# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Preparations.ChainOrder do
  @moduledoc """
  Scopes a read to one chain and sorts it in sequence order.

  The chain is named by the argument called `column`. A `nil` argument is the chain
  with no partition value: it matches rows where the column is `NULL`, not nothing.
  """

  use Ash.Resource.Preparation

  require Ash.Query
  import Ash.Expr, only: [ref: 1]

  @impl true
  def init(opts) do
    if is_atom(opts[:column]),
      do: {:ok, opts},
      else: {:error, "ChainOrder needs a :column"}
  end

  @impl true
  def prepare(query, opts, _context) do
    column = Keyword.fetch!(opts, :column)

    query =
      case Ash.Query.get_argument(query, column) do
        nil -> Ash.Query.filter(query, is_nil(^ref(column)))
        value -> Ash.Query.filter(query, ^ref(column) == ^value)
      end

    Ash.Query.sort(query, sequence: :asc)
  end
end
