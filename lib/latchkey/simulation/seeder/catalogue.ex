defmodule Latchkey.Simulation.Seeder.Catalogue do
  @moduledoc """
  Builds the seed **scenario catalogue** at demo scale (ADR 0007) — a ~100-tenancy
  board that fills the inspector with a realistic spread of arrears/exit states.

  Three **featured** scenarios (hand-authored, maximally legible) headline the board;
  the rest are **procedurally generated** across healthy / arrears / under-notice /
  exited-terminal buckets, plus a small slice of **re-lets** (ADR 0008). Every
  scenario — featured and generated alike — is a pure function of `today`: ids are
  stable slugs and every date is an offset from `today`, so a re-seed of a fresh store
  reproduces the same catalogue byte-for-byte (ADR 0005 decision 8).

  ## Agent events are derived, not planted (ADR 0011)

  The catalogue no longer hand-authors termination notices or keys-returns. It chooses,
  per scenario, a **tenant archetype**, an **agent archetype** (`:strict` = notice at 14
  days behind / `:lenient` = 30) and an **overstay** — and the world-line
  (`Latchkey.Simulation.WorldLine`) *derives* the notice date (the day arrears cross the
  agent's threshold), the termination date `E = notice + 14`, and the vacate date
  `V = E + overstay` from that tuple. `Latchkey.Simulation.Seeder.Projection` replays the
  world-line's `≤ today` slice, so a scenario sits at its intended state today by the
  **placement** of its commence date and threshold, not by planted dates:

    * **under-notice** (`:ending`) — a silent tenant whose derived notice is already
      served but whose `E`/`V` are still in the future, so today it is under an active
      notice, not yet vacated.
    * **exited** (`:terminal`) — a silent tenant whose derived `V` is already in the
      past, so the keys-return is in the `≤ today` slice and the tenancy has settled.
    * **notice-then-paid** — a tenant noticed on arrears who then paid the whole debt in
      one lump; square today, its future vacate date keeping it `:ending`.

  A scenario whose tenant never crosses its agent's threshold (a healthy tenant, or a
  mildly-behind one under a lenient agent) derives no agent events at all.

  ## Payment cadences (ADR 0009)

  Generated tenancies pay on a mix of cadences — **60 % weekly / 30 % fortnightly /
  10 % monthly** — drawn **deterministically** so the board stays a pure function of
  `today`. The split is applied to **each generated category independently**, keyed on
  that category's local `idx` via `rem(idx, 10)`: `0–5 → :weekly`, `6–8 →
  :fortnightly`, `9 → :monthly` (`cycle_for/1`). It is just the modulo — no rounding —
  so a category whose size is not a multiple of 10 fills weekly-first, and small
  categories (`exited`, `relet`) skew all-weekly, which is fine. The three featured
  headliners are **excluded** from the split and stay weekly. Each scenario's
  backdated `first_due_date` is placed by **stepping back whole cadence periods**
  (`back_periods/3`), so a scenario sits at its intended arrears/exit state regardless
  of cadence — a monthly noticed tenancy is genuinely far enough behind to clear L7.

  ## Re-lets (ADR 0008)

  A **re-let** is a genuinely **new tenancy** (new `tenancy_id`, new tenants) on the
  **same premises** (a **shared `property_ref`**), commencing after a prior tenancy
  reached terminal. Each re-let is a **pair**: a `-prior` leg (a silent tenant whose
  derived keys-return is well in the past — the exited pattern) and a `-current` leg
  sharing its `property_ref`, commencing ~2–4 weeks after the derived keys-return and
  landing active today. Because `property_address` derives from `property_ref` and
  `tenant_name` from `tenancy_id` (`Latchkey.Simulation.Identity`), the two legs show the
  **same address** but **different tenants** — the whole reason `property_ref` is on the
  log. A co-tenant change is **not** a re-let (it stays within one tenancy) and is never
  modelled as a second stream.

  Generated scenarios are **valid by construction**: the derived notice fires exactly
  when arrears cross the agent's threshold (≥ 14 days behind), so it always clears the L7
  gate and each keys-return is dated on/after the effective end date — so
  `Latchkey.Simulation.Seeder.Projection.derive/2` never raises. `:expected` is filled by
  that projection, so a scenario's stated state is the one the real domain produces.
  """

  alias Latchkey.Simulation.Behaviour.Profile
  alias Latchkey.Simulation.Seeder.Projection
  alias Latchkey.Simulation.Seeder.Scenario
  alias Latchkey.Simulation.WorldLine.Agent

  @week 7
  @base_rent_cents 50_000

  # Reliable, still-paying tenancies get their schedule extended ~5 months past today so
  # their scripted payments keep landing as wall-clock time advances — comfortably longer
  # than the quarterly reset-to-healthy re-anchor, so a live tenant never runs dry between
  # resets (the planner schedules these future payments; ADR 0011). Silent/terminal
  # scenarios deliberately keep their finite schedule — the silence *is* the truncation.
  @payment_runway_days 150

  # E = notice + 14 (s88); mirrors WorldLine so the catalogue can place a scenario's
  # commence date relative to where its derived notice/E/V will land.
  @statutory_notice_days 14

  # The generated split (the 3 featured scenarios headline on top → ~106-tenancy
  # board). Six of the terminal tenancies are re-let priors (each with a live
  # successor on the same premises); three remain plain, successor-less exits — so the
  # terminal count is unchanged while the board gains the six live re-let successors.
  @healthy_count 39
  @arrears_count 34
  @under_notice_count 15
  @exited_count 3
  @relet_count 6

  @doc """
  The full catalogue as a pure function of `today` — featured ++ generated, each with
  its derived `:expected` filled in.
  """
  @spec build(Date.t()) :: [Scenario.t()]
  def build(%Date{} = today) do
    (featured(today) ++ generated(today))
    |> Enum.map(&fill_property_ref/1)
    |> Enum.map(fn scenario -> %{scenario | expected: Projection.derive(scenario, today)} end)
  end

  # Every scenario carries a non-PII `property_ref` on its `TenancyCommenced` (ADR
  # 0008). The 1:1 majority gets a **unique** ref derived from its own slug; re-let
  # scenarios set a **shared** ref explicitly (both legs, same premises) — keep those.
  defp fill_property_ref(%Scenario{property_ref: nil} = scenario),
    do: %{scenario | property_ref: "prop-" <> scenario.tenancy_id}

  defp fill_property_ref(%Scenario{} = scenario), do: scenario

  # ── featured (hand-authored, headline scenarios) ──────────────────────────────

  @doc "The three legible, hand-authored headline scenarios (`:expected` not yet filled)."
  @spec featured(Date.t()) :: [Scenario.t()]
  def featured(%Date{} = today) do
    [paid_up(today), twenty_days_behind(today), notice_then_paid(today)]
  end

  # A reliable tenant who has paid every period up to today — square, `days_behind` 0 —
  # and keeps paying: the schedule runs a runway past today (weekly cadence) so this
  # headline "square" tenant stays square as the sweep advances, rather than drifting.
  defp paid_up(today) do
    %Scenario{
      label: "paid-up",
      tenancy_id: "paid-up",
      rent_amount_cents: @base_rent_cents,
      first_due_date: days_before(today, 30),
      profile: Profile.reliable(),
      schedule_count: 5 + future_periods(:weekly)
    }
  end

  # Paid two weeks on time, then went silent. The first unpaid period fell due 20 days
  # ago, so `days_behind` is 20 today — eligible under L7, but the assigned agent is
  # `:lenient` (30-day threshold), so no notice is derived: the arrears cross 30 only in
  # the future, past the `≤ today` slice.
  defp twenty_days_behind(today) do
    %Scenario{
      label: "20-days-behind-no-notice",
      tenancy_id: "arrears-no-notice",
      rent_amount_cents: @base_rent_cents,
      first_due_date: days_before(today, 34),
      profile: Profile.reliable(),
      schedule_count: 2,
      agent_archetype: :lenient
    }
  end

  # Missed the opening two weeks, so a termination notice was derived the day arrears
  # crossed the strict L7 gate (14 days behind); the tenant then paid the whole accrued
  # debt in a single lump and stayed current. The vacate date the notice sets in motion
  # is still weeks out (overstay 21), so the tenancy is square today yet still `:ending`.
  defp notice_then_paid(today) do
    rent = @base_rent_cents

    profile =
      Profile.reliable()
      |> Profile.with_override(0, :miss)
      |> Profile.with_override(1, :miss)
      |> Profile.with_override(2, {:pay, amount_cents: 3 * rent})

    %Scenario{
      label: "notice-issued-then-tenant-paid",
      tenancy_id: "notice-then-paid",
      rent_amount_cents: rent,
      first_due_date: days_before(today, 21),
      profile: profile,
      schedule_count: 4,
      agent_archetype: :strict,
      overstay_days: 21
    }
  end

  # ── generated (procedural spread) ─────────────────────────────────────────────

  defp generated(today) do
    healthy(today) ++ arrears(today) ++ under_notice(today) ++ exited(today) ++ relets(today)
  end

  # Reliable tenants square today: the `periods` past periods are all paid up to today,
  # then the schedule runs a `future_periods/1` runway *past* today so the tenant keeps
  # paying as wall-clock time advances (the planner schedules those; ADR 0011). `first_due`
  # is stepped back `periods` whole cadence periods from `today` (then nudged `offset` days
  # forward), so it stays square on any cadence.
  defp healthy(today) do
    for idx <- 0..(@healthy_count - 1) do
      cycle = cycle_for(idx)
      periods = 6 + rem(idx, 8)
      offset = 1 + rem(idx, 6)

      %Scenario{
        label: "healthy-#{pad(idx + 1)}",
        tenancy_id: "healthy-#{pad(idx + 1)}",
        rent_amount_cents: rent(idx),
        cycle: cycle,
        first_due_date: Date.add(back_periods(today, cycle, periods), offset),
        profile: Profile.reliable(),
        schedule_count: periods + future_periods(cycle)
      }
    end
  end

  # Paid a few periods on time, then went silent — `:active`, un-noticed today. The
  # schedule ends at the paid periods, so the world-line's arrears trajectory never
  # climbs and no notice is derived; the sweep alone reveals the debt. `days_behind`
  # spreads a couple of days to ~4 weeks (both pre- and post-L7 but under 30), and the
  # agent is `:lenient` so the intended reading is coherent: a recently-silent tenant not
  # yet at its agent's threshold, rather than one the agent has simply failed to notice.
  defp arrears(today) do
    for idx <- 0..(@arrears_count - 1) do
      cycle = cycle_for(idx)
      paid = 1 + rem(idx, 3)
      days_behind = 2 + rem(idx * 9 + 3, 27)

      %Scenario{
        label: "arrears-#{pad(idx + 1)}",
        tenancy_id: "arrears-#{pad(idx + 1)}",
        rent_amount_cents: rent(idx),
        cycle: cycle,
        # The first unpaid period falls due `days_behind` ago; step back `paid` whole
        # cadence periods from there to the anchor, so `days_behind` holds on any cadence.
        first_due_date: back_periods(days_before(today, days_behind), cycle, paid),
        profile: Profile.reliable(),
        schedule_count: paid,
        agent_archetype: :lenient
      }
    end
  end

  # Fell into arrears and the world-line derived a still-standing termination notice
  # whose end date `E` is in the future — `:ending` today. The silent tenant's arrears
  # cross the agent's threshold (`:strict`/`:lenient` alternating for demo variety) in the
  # past, but `E` (and the compliant `V = E`) stay in the future, so no keys-return lands
  # in the `≤ today` slice.
  defp under_notice(today) do
    for idx <- 0..(@under_notice_count - 1) do
      cycle = cycle_for(idx)
      paid = 1 + rem(idx, 3)
      archetype = if rem(idx, 2) == 0, do: :strict, else: :lenient
      # First unpaid `first_unpaid_age` days ago — a few days past the threshold (so the
      # notice is served) but within `threshold + 14`, so `E = notice + 14` is still
      # future and the tenancy has not yet crossed into vacate. `days_behind` == age.
      first_unpaid_age = Agent.threshold_days(archetype) + 3 + rem(idx, 3) * 5

      %Scenario{
        label: "under-notice-#{pad(idx + 1)}",
        tenancy_id: "under-notice-#{pad(idx + 1)}",
        rent_amount_cents: rent(idx),
        cycle: cycle,
        first_due_date: back_periods(days_before(today, first_unpaid_age), cycle, paid),
        profile: silent_after(paid),
        schedule_count: paid + 2,
        agent_archetype: archetype
      }
    end
  end

  # Fell into deep arrears, was noticed, and vacated — settled to `:terminal`. The
  # strict notice, its end date `E`, and the derived vacate date `V` are all in the past,
  # so the keys-return is in the `≤ today` slice. Some held over past `E` (overstay > 0),
  # some left on it.
  defp exited(today) do
    for idx <- 0..(@exited_count - 1) do
      cycle = cycle_for(idx)
      paid = 1 + rem(idx, 3)
      first_unpaid_age = 63 + rem(idx, 3) * @week
      overstay = rem(idx, 3) * 4

      %Scenario{
        label: "exited-#{pad(idx + 1)}",
        tenancy_id: "exited-#{pad(idx + 1)}",
        rent_amount_cents: rent(idx),
        cycle: cycle,
        first_due_date: back_periods(days_before(today, first_unpaid_age), cycle, paid),
        profile: silent_after(paid),
        schedule_count: paid + 2,
        agent_archetype: :strict,
        overstay_days: overstay
      }
    end
  end

  # ── re-lets (successive tenancies on the same premises, ADR 0008) ──────────────

  # Each re-let is a **pair** sharing one `property_ref`: a terminal `-prior` leg
  # (derived keys-return well in the past) and a live `-current` leg commencing ~2–4
  # weeks after that keys-return. Same premises (shared ref ⇒ same address), different
  # tenants (distinct ids ⇒ different names). Pure function of `today`.
  defp relets(today) do
    Enum.flat_map(0..(@relet_count - 1), &relet_pair(today, &1))
  end

  defp relet_pair(today, idx) do
    n = pad(idx + 1)
    property_ref = "prop-relet-#{n}"
    rent = rent(idx)
    cycle = cycle_for(idx)

    # Prior leg (the exited/terminal pattern, dated further back so the successor has
    # room to run): a silent tenant, strict-noticed on arrears, keys returned 8–11 weeks
    # ago. `prior_keys_age` is the *derived* vacate date `V` = first-unpaid − 14 (notice)
    # − 14 (E) − overstay, computed here so the current leg can commence after it.
    prior_paid = 1 + rem(idx, 3)
    prior_first_unpaid_age = 91 + rem(idx, 3) * @week
    prior_overstay = rem(idx, 2) * 4
    prior_keys_age = prior_first_unpaid_age - 2 * @statutory_notice_days - prior_overstay

    prior = %Scenario{
      label: "relet-#{n}-prior",
      tenancy_id: "relet-#{n}-prior",
      property_ref: property_ref,
      rent_amount_cents: rent,
      cycle: cycle,
      first_due_date: back_periods(days_before(today, prior_first_unpaid_age), cycle, prior_paid),
      profile: silent_after(prior_paid),
      schedule_count: prior_paid + 2,
      agent_archetype: :strict,
      overstay_days: prior_overstay
    }

    # Current leg: a new tenancy on the same premises, commencing 2–4 weeks after the
    # prior keys-return. Even indices land paid-up, odd indices a mild arrears — so the
    # live re-lets spread across states like the rest of the board. Reliable + a schedule
    # ending at the paid periods ⇒ no arrears cross the world-line ⇒ no notice, `:active`.
    commence_age = prior_keys_age - (14 + rem(idx, 3) * @week)
    elapsed_weeks = max(1, div(commence_age, @week))
    mild_arrears? = rem(idx, 2) == 1
    paid = if mild_arrears?, do: max(1, elapsed_weeks - 1), else: elapsed_weeks + 1

    # The paid-up successors keep paying past today (runway added); the mild-arrears ones
    # keep their finite schedule so they stay a little behind, as before.
    schedule_count = if mild_arrears?, do: paid, else: paid + future_periods(cycle)

    current = %Scenario{
      label: "relet-#{n}-current",
      tenancy_id: "relet-#{n}-current",
      property_ref: property_ref,
      rent_amount_cents: rent,
      cycle: cycle,
      first_due_date: days_before(today, commence_age),
      profile: Profile.reliable(),
      schedule_count: schedule_count
    }

    [prior, current]
  end

  # ── helpers ───────────────────────────────────────────────────────────────────

  # A tenant who pays `paid` periods on time then goes silent, missing every period
  # thereafter — the arrears trajectory the world-line folds to derive the agent's
  # reaction. `step_days: 100` is larger than any cadence's period, so the first
  # post-grace period is instantly a whole period behind and misses, on any cadence.
  defp silent_after(paid) do
    Profile.deteriorating(grace_periods: paid, step_days: 100, period_length_days: 7)
  end

  # The deterministic 60/30/10 cadence draw (ADR 0009 decision 1): keyed on a
  # category's local `idx` via `rem(idx, 10)` — 0–5 weekly, 6–8 fortnightly, 9 monthly.
  # Pure modulo, no rounding; a category smaller than 10 skews weekly, by design.
  defp cycle_for(idx) do
    case rem(idx, 10) do
      r when r in 0..5 -> :weekly
      r when r in 6..8 -> :fortnightly
      _ -> :monthly
    end
  end

  # Step `date` back by `n` whole cadence periods — the inverse of the Schedule/aggregate
  # forward walk (weekly `-7·n`, fortnightly `-14·n`, monthly `Date.shift(month: -n)`
  # from the anchor). Used to place a backdated `first_due_date` `n` paid periods before a
  # target due date, so a scenario sits at its intended state on any cadence. Monthly
  # month-end clamping means `forward(back(d, n), n)` can differ from `d` by a couple of
  # days after a short month — well inside the arrears margins the callers leave.
  defp back_periods(%Date{} = date, :weekly, n), do: Date.add(date, -7 * n)
  defp back_periods(%Date{} = date, :fortnightly, n), do: Date.add(date, -14 * n)
  defp back_periods(%Date{} = date, :monthly, n), do: Date.shift(date, month: -n)

  # Future cadence periods covering `@payment_runway_days` — the runway added to an
  # ongoing reliable payer's schedule so it keeps paying past today (the shortest month
  # is used for monthly so the day-count is never under-covered).
  defp future_periods(:weekly), do: ceil(@payment_runway_days / 7)
  defp future_periods(:fortnightly), do: ceil(@payment_runway_days / 14)
  defp future_periods(:monthly), do: ceil(@payment_runway_days / 28)

  # A little deterministic rent variation (45k..70k) so the board isn't monotone. This is
  # the whole-period rent for the tenancy's cadence (ADR 0009 decision 1).
  defp rent(idx), do: 45_000 + rem(idx, 6) * 5_000

  defp days_before(%Date{} = date, days), do: Date.add(date, -days)

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
