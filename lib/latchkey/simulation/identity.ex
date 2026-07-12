defmodule Latchkey.Simulation.Identity do
  @moduledoc """
  Deterministic display identity for a seeded tenancy (ADR 0008) — the values the
  `Latchkey.Simulation.Directory` read model stores. **Seed-time only**; never on the
  event log.

  ## Two independent keys — the re-let refinement

    * `property_address` derives from **`property_ref`**, so two tenancies that share
      a `property_ref` (a re-let: a new tenancy on the same premises) resolve to the
      **same address**;
    * `tenant_name` derives from **`tenancy_id`**, so those same two tenancies resolve
      to **different tenants**.

  For the 1:1 majority (a unique `property_ref` per tenancy) this is indistinguishable
  from keying everything off `tenancy_id`; only re-let pairs make the split observable.

  ## Determinism without leaking RNG

  Faker draws from the process `:rand` state. To make identity a pure function of its
  key while keeping the seed reproducible (ADR 0005 decision 8), each draw:

    1. saves the caller's prior `:rand` state (`:rand.export_seed/0`, which may be
       `:undefined` if the process never seeded);
    2. seeds `:rand` deterministically from the key;
    3. draws from Faker; and
    4. **restores** the prior state in an `after` block, so the deterministic seed
       never leaks into the caller's subsequent RNG.

  Same inputs ⇒ identical identity; a full re-seed reproduces the whole Directory.

  ## Locale

  Faker has no en_AU locale, so addresses render in Faker's default US style. The
  Directory is disposable demo data, so this is cosmetic and intentionally not worth
  chasing a custom locale for.
  """

  @typedoc "The display identity resolved for a tenancy."
  @type t :: %{tenant_name: String.t(), property_address: String.t()}

  @doc """
  Resolve the deterministic display identity for a tenancy: `tenant_name` keyed off
  `tenancy_id`, `property_address` keyed off `property_ref`.
  """
  @spec resolve(String.t(), String.t()) :: t()
  def resolve(tenancy_id, property_ref)
      when is_binary(tenancy_id) and is_binary(property_ref) do
    %{
      tenant_name: seeded(tenancy_id, &draw_name/0),
      property_address: seeded(property_ref, &draw_address/0)
    }
  end

  defp draw_name, do: Faker.Person.name()

  defp draw_address do
    "#{Faker.Address.street_address()}, #{Faker.Address.city()} " <>
      "#{Faker.Address.state_abbr()} #{Faker.Address.zip_code()}"
  end

  # Draw `fun` from a `:rand` state seeded deterministically off `key`, then restore
  # the caller's prior state so the deterministic seed never leaks.
  defp seeded(key, fun) do
    prior = :rand.export_seed()

    :rand.seed(
      :exsss,
      {:erlang.phash2({key, 0}), :erlang.phash2({key, 1}), :erlang.phash2({key, 2})}
    )

    try do
      fun.()
    after
      restore(prior)
    end
  end

  # No prior state (the process never drew): reseed non-deterministically so we still
  # leave no deterministic residue behind.
  defp restore(:undefined), do: :rand.seed(:exsss)
  defp restore(prior), do: :rand.seed(prior)
end
