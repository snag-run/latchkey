defmodule Latchkey.Clock do
  @moduledoc """
  The single wall-clock read-site for the application.

  Per [ADR 0005](../../docs/adr/0005-simulation-and-time-model.md), "now" for the
  live path is wall-clock time read in `Australia/Sydney`, DST-aware. The domain
  stays pure: `decide` code threads an explicit `as_of` date and **never** calls
  the Clock. Read this here, at the edge, and pass the resulting date inward.
  """

  @time_zone "Australia/Sydney"

  @doc """
  Today's date in `Australia/Sydney`, resolved from the current wall-clock instant.
  """
  @spec today() :: Date.t()
  def today, do: today(DateTime.utc_now())

  @doc """
  The `Australia/Sydney` calendar date for a given UTC instant.

  Splitting out the instant makes the zone-boundary behaviour deterministically
  testable: an instant that falls on a different calendar day in UTC resolves to
  the Sydney date.
  """
  @spec today(DateTime.t()) :: Date.t()
  def today(%DateTime{} = instant) do
    instant
    |> DateTime.shift_zone!(@time_zone)
    |> DateTime.to_date()
  end
end
