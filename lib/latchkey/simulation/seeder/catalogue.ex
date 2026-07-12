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

  ## Re-lets (ADR 0008)

  A **re-let** is a genuinely **new tenancy** (new `tenancy_id`, new tenants) on the
  **same premises** (a **shared `property_ref`**), commencing after a prior tenancy
  reached terminal. Each re-let is a **pair**: a `-prior` leg (noticed, keys returned
  well in the past — the existing exited pattern) and a `-current` leg sharing its
  `property_ref`, commencing ~2–4 weeks after the prior keys-return and landing active
  today. Because `property_address` derives from `property_ref` and `tenant_name` from
  `tenancy_id` (`Latchkey.Simulation.Identity`), the two legs show the **same address**
  but **different tenants** — the whole reason `property_ref` is on the log. A
  co-tenant change is **not** a re-let (it stays within one tenancy) and is never
  modelled as a second stream.

  Generated scenarios are **valid by construction**: each planted notice clears the
  L7 arrears gate at its assessment date and each keys-return is dated on/after the
  effective end date, so `Latchkey.Simulation.Seeder.Projection.derive/2` never raises
  and the live seed never rejects a planted step. `:expected` is filled by that
  projection, so a scenario's stated state is the one the real domain produces.
  """

  alias Latchkey.Simulation.Behaviour.Profile
  alias Latchkey.Simulation.Seeder.Projection
  alias Latchkey.Simulation.Seeder.Scenario

  @week 7
  @base_rent_cents 50_000

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

  # A reliable tenant who has paid every period up to today — square, `days_behind` 0.
  defp paid_up(today) do
    %Scenario{
      label: "paid-up",
      tenancy_id: "paid-up",
      rent_amount_cents: @base_rent_cents,
      first_due_date: days_before(today, 30),
      profile: Profile.reliable(),
      schedule_count: 5,
      notice: nil
    }
  end

  # Paid two weeks on time, then went silent. The first unpaid period fell due 20 days
  # ago, so `days_behind` is 20 today — eligible under L7, but no notice is planted.
  defp twenty_days_behind(today) do
    %Scenario{
      label: "20-days-behind-no-notice",
      tenancy_id: "arrears-no-notice",
      rent_amount_cents: @base_rent_cents,
      first_due_date: days_before(today, 34),
      profile: Profile.reliable(),
      schedule_count: 2,
      notice: nil
    }
  end

  # Missed the opening weeks; the agent issued a termination notice 21 days ago; then
  # the tenant paid the entire debt in one lump. The notice's end date is a week out,
  # so no more rent accrues past it — the tenant is square today, still `:ending`.
  defp notice_then_paid(today) do
    lump_cents = 7 * @base_rent_cents

    profile =
      Profile.reliable()
      |> Profile.with_override(0, :miss)
      |> Profile.with_override(1, :miss)
      |> Profile.with_override(2, :miss)
      |> Profile.with_override(3, :miss)
      |> Profile.with_override(4, {:pay, amount_cents: lump_cents})

    %Scenario{
      label: "notice-issued-then-tenant-paid",
      tenancy_id: "notice-then-paid",
      rent_amount_cents: @base_rent_cents,
      first_due_date: days_before(today, 42),
      profile: profile,
      schedule_count: 5,
      notice: %{
        given_on: days_before(today, 21),
        as_of: days_before(today, 21),
        termination_date: Date.add(today, @week)
      }
    }
  end

  # ── generated (procedural spread) ─────────────────────────────────────────────

  defp generated(today) do
    healthy(today) ++ arrears(today) ++ under_notice(today) ++ exited(today) ++ relets(today)
  end

  # Reliable tenants square today: the schedule spans `weeks` paid periods, and the
  # first_due offset lands the *next* due date after today, so nothing dangles unpaid.
  defp healthy(today) do
    for idx <- 0..(@healthy_count - 1) do
      weeks = 6 + rem(idx, 8)
      offset = 1 + rem(idx, 6)

      %Scenario{
        label: "healthy-#{pad(idx + 1)}",
        tenancy_id: "healthy-#{pad(idx + 1)}",
        rent_amount_cents: rent(idx),
        first_due_date: days_before(today, weeks * @week - offset),
        profile: Profile.reliable(),
        schedule_count: weeks
      }
    end
  end

  # Paid a few periods on time, then went silent — no notice. `days_behind` spreads
  # from a couple of days to ~8 weeks so the board shows both pre- and post-L7 arrears.
  defp arrears(today) do
    for idx <- 0..(@arrears_count - 1) do
      paid = 1 + rem(idx, 3)
      days_behind = 2 + rem(idx * 9 + 3, 55)

      %Scenario{
        label: "arrears-#{pad(idx + 1)}",
        tenancy_id: "arrears-#{pad(idx + 1)}",
        rent_amount_cents: rent(idx),
        first_due_date: days_before(today, days_behind + paid * @week),
        profile: Profile.reliable(),
        schedule_count: paid
      }
    end
  end

  # Fell into arrears, then the agent issued a still-standing termination notice whose
  # end date is in the future — `:ending` today. The notice clears the L7 gate by
  # construction (>= 21 days behind at its assessment date).
  defp under_notice(today) do
    for idx <- 0..(@under_notice_count - 1) do
      paid = 1 + rem(idx, 3)
      notice_age = @week + rem(idx, 3) * @week
      first_unpaid_age = first_unpaid_age(idx, notice_age)

      %Scenario{
        label: "under-notice-#{pad(idx + 1)}",
        tenancy_id: "under-notice-#{pad(idx + 1)}",
        rent_amount_cents: rent(idx),
        first_due_date: days_before(today, first_unpaid_age + paid * @week),
        profile: Profile.reliable(),
        schedule_count: paid,
        notice: %{
          given_on: days_before(today, notice_age),
          as_of: days_before(today, notice_age),
          termination_date: Date.add(today, 3 + rem(idx, 3) * 4)
        }
      }
    end
  end

  # Fell into arrears, was noticed with a now-past end date, and returned the keys —
  # settled to `:terminal`. Some held over past the end date (V > E), some left on it.
  defp exited(today) do
    for idx <- 0..(@exited_count - 1) do
      paid = 1 + rem(idx, 3)
      notice_age = 42 + rem(idx, 3) * @week
      first_unpaid_age = first_unpaid_age(idx, notice_age)
      end_age = notice_age - (14 + rem(idx, 2) * @week)
      overstay = rem(idx, 3) * 3

      %Scenario{
        label: "exited-#{pad(idx + 1)}",
        tenancy_id: "exited-#{pad(idx + 1)}",
        rent_amount_cents: rent(idx),
        first_due_date: days_before(today, first_unpaid_age + paid * @week),
        profile: Profile.reliable(),
        schedule_count: paid,
        notice: %{
          given_on: days_before(today, notice_age),
          as_of: days_before(today, notice_age),
          termination_date: days_before(today, end_age)
        },
        exit: %{keys_on: days_before(today, end_age - overstay)}
      }
    end
  end

  # ── re-lets (successive tenancies on the same premises, ADR 0008) ──────────────

  # Each re-let is a **pair** sharing one `property_ref`: a terminal `-prior` leg
  # (keys returned well in the past) and a live `-current` leg commencing ~2–4 weeks
  # after that keys-return. Same premises (shared ref ⇒ same address), different
  # tenants (distinct ids ⇒ different names). Pure function of `today`.
  defp relets(today) do
    Enum.flat_map(0..(@relet_count - 1), &relet_pair(today, &1))
  end

  defp relet_pair(today, idx) do
    n = pad(idx + 1)
    property_ref = "prop-relet-#{n}"
    rent = rent(idx)

    # Prior leg (the existing exited/terminal pattern, but dated further back so the
    # successor has room to run): noticed on arrears, keys returned 8–11 weeks ago.
    prior_end_age = 63 + rem(idx, 3) * @week
    prior_notice_age = prior_end_age + 21
    prior_first_unpaid_age = first_unpaid_age(idx, prior_notice_age)
    prior_paid = 1 + rem(idx, 3)
    prior_keys_age = prior_end_age - rem(idx, 2) * 4

    prior = %Scenario{
      label: "relet-#{n}-prior",
      tenancy_id: "relet-#{n}-prior",
      property_ref: property_ref,
      rent_amount_cents: rent,
      first_due_date: days_before(today, prior_first_unpaid_age + prior_paid * @week),
      profile: Profile.reliable(),
      schedule_count: prior_paid,
      notice: %{
        given_on: days_before(today, prior_notice_age),
        as_of: days_before(today, prior_notice_age),
        termination_date: days_before(today, prior_end_age)
      },
      exit: %{keys_on: days_before(today, prior_keys_age)}
    }

    # Current leg: a new tenancy on the same premises, commencing 2–4 weeks after the
    # prior keys-return. Even indices land paid-up, odd indices a mild arrears — so the
    # live re-lets spread across states like the rest of the board.
    commence_age = prior_keys_age - (14 + rem(idx, 3) * @week)
    elapsed_weeks = max(1, div(commence_age, @week))
    mild_arrears? = rem(idx, 2) == 1
    paid = if mild_arrears?, do: max(1, elapsed_weeks - 1), else: elapsed_weeks + 1

    current = %Scenario{
      label: "relet-#{n}-current",
      tenancy_id: "relet-#{n}-current",
      property_ref: property_ref,
      rent_amount_cents: rent,
      first_due_date: days_before(today, commence_age),
      profile: Profile.reliable(),
      schedule_count: paid
    }

    [prior, current]
  end

  # ── helpers ───────────────────────────────────────────────────────────────────

  # How long ago the first unpaid period fell due for a noticed tenancy: the notice
  # landed `notice_age` days ago, by which point the tenant was 21..28 days in arrears
  # (>= the L7 gate, so the planted notice is valid by construction).
  defp first_unpaid_age(idx, notice_age), do: notice_age + 21 + rem(idx, 2) * @week

  # A little deterministic rent variation (45k..70k) so the board isn't monotone.
  defp rent(idx), do: 45_000 + rem(idx, 6) * 5_000

  defp days_before(%Date{} = date, days), do: Date.add(date, -days)

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
