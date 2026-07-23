# Seed the scenario catalogue — a board of tenancies in interesting, legible
# arrears/exit states, each engineered to sit at a chosen state today (ADR 0005
# decision 9 / issue #44). Run it against a fresh store:
#
#     mix ecto.reset && mix run priv/repo/seeds.exs
#
# Seeding replays the live behaviour engine + sweep over historical dates through the
# real Accounts → ACL-1 → PM seam, so the seeded history is identical to what the live
# loop would have produced. Re-running against an already-seeded store is a coarse
# no-op: each already-commenced tenancy is skipped.
#
# Then the planner realizes the *future* (ADR 0011): it folds each tenancy's world-line
# and enqueues the `> today` events — future payments and the derived agent actions
# (notice/vacate) — as scheduled Oban jobs, so the board keeps evolving AFK (reliable
# tenants keep paying as time advances; issue #200). Idempotent on `{tenancy_id, ref}`,
# so this is safe to re-run.

alias Latchkey.Simulation.Planner
alias Latchkey.Simulation.Seeder

results = Seeder.seed()

IO.puts("\nSeeded scenario catalogue:\n")

Enum.each(results, fn %{scenario: scenario, tenancy_id: tenancy_id, status: status} ->
  IO.puts("  [#{status}] #{scenario.label} (#{tenancy_id})")
end)

scheduled = Planner.plan()

IO.puts("\nScheduled #{length(scheduled)} future world-line event(s).\n")
