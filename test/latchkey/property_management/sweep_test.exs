defmodule Latchkey.PropertyManagement.SweepTest do
  @moduledoc """
  The sweep's pure/fan-out seam (ADR 0005 decision 5): which tenancies to sweep, the
  `CatchUp` command issued for each, and the cron's per-tenancy child-job fan-out.
  No Commanded here — the cron only *enqueues*; dispatch is proven in the integration
  test.
  """
  use Latchkey.DataCase, async: false
  use Oban.Testing, repo: Latchkey.Repo

  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Sweep
  alias Latchkey.PropertyManagement.Sweep.CronWorker
  alias Latchkey.PropertyManagement.Sweep.TenancyWorker
  alias Latchkey.PropertyManagement.Tenancy.Commands.CatchUp

  defp seed_arrears(tenancy_id) do
    Arrears
    |> Ash.Changeset.for_create(:upsert, %{
      tenancy_id: tenancy_id,
      balance_cents: 0,
      oldest_unpaid_due_date: nil
    })
    |> Ash.create!()
  end

  describe "catch_up_command/2" do
    test "builds a CatchUp for the tenancy swept through as_of, recorded_on left nil" do
      assert %CatchUp{tenancy_id: "t-1", as_of: ~D[2026-03-20], recorded_on: nil} =
               Sweep.catch_up_command("t-1", ~D[2026-03-20])
    end
  end

  describe "live_tenancy_ids/0" do
    test "returns a tenancy id per row in the Arrears read model" do
      seed_arrears("t-a")
      seed_arrears("t-b")

      assert Enum.sort(Sweep.live_tenancy_ids()) == ["t-a", "t-b"]
    end

    test "is empty when no tenancy has commenced" do
      assert Sweep.live_tenancy_ids() == []
    end
  end

  describe "CronWorker fan-out" do
    test "enqueues one TenancyWorker child per live tenancy, swept through a single as_of" do
      seed_arrears("t-a")
      seed_arrears("t-b")

      assert :ok = perform_job(CronWorker, %{})

      jobs = all_enqueued(worker: TenancyWorker)

      # Derive the expected as_of from the jobs the worker actually enqueued rather
      # than reading Clock.today/0 a second time here — a midnight-cross between the
      # two reads would flake the assertion. A single cron run is one consistent
      # snapshot, so every child must share exactly one as_of.
      assert [as_of] = jobs |> Enum.map(& &1.args["as_of"]) |> Enum.uniq()

      # Both live tenancies each got exactly one job, swept through that as_of.
      assert_enqueued(worker: TenancyWorker, args: %{tenancy_id: "t-a", as_of: as_of})
      assert_enqueued(worker: TenancyWorker, args: %{tenancy_id: "t-b", as_of: as_of})
      assert length(jobs) == 2
    end

    test "enqueues nothing when there are no live tenancies" do
      assert :ok = perform_job(CronWorker, %{})
      assert all_enqueued(worker: TenancyWorker) == []
    end
  end
end
