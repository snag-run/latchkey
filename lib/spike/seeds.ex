defmodule Spike.Seeds do
  @moduledoc """
  Realistic seed data for the ES bake-off, applied to EITHER backend so you can
  poke both. Four Sydney tenancies chosen to land on the interesting sides of the
  L7 arrears gate (as of #{inspect(~D[2026-07-11])}):

    * bondi       — paid up (gate refuses)
    * marrickville— 7 days behind (gate refuses — under 14)
    * newtown     — 42 days behind, never paid (gate ACCEPTS)
    * glebe       — fell behind then caught up FIFO (gate refuses — remedied)

  Weekly cycle only (slice scope). `seed_ash/0` and `seed_commanded/0` replay the
  same scenarios through each foundation, then a lazy catch-up warms the read model.
  """
  alias Spike.AshEvents.Tenancy, as: AshTenancy

  alias Spike.Commanded.App
  alias Spike.Commanded.Commands, as: C

  @as_of ~D[2026-07-11]

  def as_of, do: @as_of

  @scenarios [
    %{
      id: "seed-bondi",
      address: "21 Bright St, Bondi",
      rent: 65_000,
      first_due: ~D[2026-06-06],
      weeks_paid: 6
    },
    %{
      id: "seed-marrickville",
      address: "8 Marrickville Rd",
      rent: 58_000,
      first_due: ~D[2026-06-27],
      weeks_paid: 1
    },
    %{
      id: "seed-newtown",
      address: "44 Enmore Rd, Newtown",
      rent: 70_000,
      first_due: ~D[2026-05-30],
      weeks_paid: 0
    },
    %{
      id: "seed-glebe",
      address: "12 Glebe Point Rd",
      rent: 62_000,
      first_due: ~D[2026-05-16],
      weeks_paid: 8
    }
  ]

  def scenarios, do: @scenarios

  @doc "Due dates from first_due up to and including as_of (weekly)."
  def due_dates(%{first_due: first_due}) do
    first_due
    |> Stream.iterate(&Date.add(&1, 7))
    |> Enum.take_while(&(Date.compare(&1, @as_of) != :gt))
  end

  defp payments(%{id: id, rent: rent} = s) do
    s
    |> due_dates()
    |> Enum.take(s.weeks_paid)
    |> Enum.with_index(1)
    |> Enum.map(fn {due, n} ->
      %{amount_cents: rent, received_on: due, source_payment_id: "#{id}-pay-#{n}"}
    end)
  end

  # ── pure-Ash backend ────────────────────────────────────────────────────────

  def seed_ash do
    for s <- @scenarios do
      _ =
        AshTenancy.commence(%{
          tenancy_id: s.id,
          rent_amount_cents: s.rent,
          cycle: :weekly,
          first_due_date: s.first_due
        })

      for p <- payments(s), do: AshTenancy.record_payment(Map.put(p, :tenancy_id, s.id))
      AshTenancy.catch_up(%{tenancy_id: s.id, as_of: @as_of})
    end

    :ok
  end

  # ── raw-Commanded backend ───────────────────────────────────────────────────

  def seed_commanded do
    for s <- @scenarios do
      dispatch(%C.CommenceTenancy{
        tenancy_id: s.id,
        rent_amount_cents: s.rent,
        cycle: :weekly,
        first_due_date: s.first_due
      })

      for p <- payments(s) do
        dispatch(struct(C.RecordPayment, Map.put(p, :tenancy_id, s.id)))
      end

      dispatch(%C.CatchUp{tenancy_id: s.id, as_of: @as_of})
    end

    :ok
  end

  # commence on a re-seed returns {:error, :already_commenced}; treat as idempotent.
  defp dispatch(cmd) do
    App.dispatch(cmd, consistency: :strong)
  end
end
