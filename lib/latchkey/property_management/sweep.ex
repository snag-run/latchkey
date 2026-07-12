defmodule Latchkey.PropertyManagement.Sweep do
  @moduledoc """
  The daily sweep (ADR 0005 decision 5) — the **visibility backstop for non-payers**.

  A paying tenant catches *itself* up: `decide_payment` books the periods owed since
  last time before recording a payment. The only tenancies that never receive a
  command are the ones that **stopped paying** — and those are exactly the ones that
  need to surface in arrears. Until swept, an unbooked due date reads as
  `oldest_unpaid_due_date = nil` (the tenant looks paid up); the sweep reveals the
  silence by booking the owed `RentFellDue`s.

  This module holds the sweep's **pure seam** — which tenancies to sweep and the
  `CatchUp` command to issue for each. The Oban wiring (cron fan-out + per-tenancy
  dispatch) lives in `Latchkey.PropertyManagement.Sweep.CronWorker` /
  `Latchkey.PropertyManagement.Sweep.TenancyWorker`.

  It **never issues notices** — eligibility only *surfaces* an affordance; the human
  agent chooses whether and when to act (ADR 0005 decision 1).
  """

  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy.Commands.CatchUp

  @doc """
  The `CatchUp` command to issue for one tenancy, swept through `as_of`.

  `recorded_on` is left `nil` so the aggregate books it at the edge as `Clock.today/0`
  — a swept-in `RentFellDue` therefore carries `recorded_on >= occurred_on` (lazy
  accrual, not backdating; ADR 0005 decision 4).
  """
  @spec catch_up_command(String.t(), Date.t()) :: CatchUp.t()
  def catch_up_command(tenancy_id, %Date{} = as_of) when is_binary(tenancy_id) do
    %CatchUp{tenancy_id: tenancy_id, as_of: as_of}
  end

  @doc """
  Tenancy ids of every live tenancy — the sweep's fan-out set.

  Sourced from the `Arrears` read model, which holds a row per commenced tenancy.
  Dispatching `CatchUp` to a pending tenancy is a harmless no-op (`decide_catch_up`
  emits nothing), so the read model is a safe registry.
  """
  @spec live_tenancy_ids() :: [String.t()]
  def live_tenancy_ids do
    Arrears
    |> Ash.read!()
    |> Enum.map(& &1.tenancy_id)
  end
end
