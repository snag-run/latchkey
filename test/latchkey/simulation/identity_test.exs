defmodule Latchkey.Simulation.IdentityTest do
  @moduledoc """
  The deterministic display-identity derivation (ADR 0008): name keyed off
  `tenancy_id`, address keyed off `property_ref`, with a reproducible seed that never
  leaks into the caller's `:rand` state.
  """
  use ExUnit.Case, async: true

  alias Latchkey.Simulation.Identity

  describe "resolve/2" do
    test "is deterministic — same inputs yield identical identity" do
      assert Identity.resolve("healthy-01", "prop-healthy-01") ==
               Identity.resolve("healthy-01", "prop-healthy-01")
    end

    test "returns a name and an address" do
      %{tenant_name: name, property_address: address} =
        Identity.resolve("arrears-07", "prop-arrears-07")

      assert is_binary(name) and name != ""
      assert is_binary(address) and address != ""
    end

    test "different tenancies resolve to different tenants" do
      a = Identity.resolve("healthy-01", "prop-healthy-01")
      b = Identity.resolve("healthy-02", "prop-healthy-02")

      assert a.tenant_name != b.tenant_name
    end

    test "a re-let pair shares an address but has different tenants" do
      # Same premises (shared property_ref), distinct tenancies (distinct ids) — the
      # crux of re-lets.
      shared_ref = "prop-relet-01"
      prior = Identity.resolve("relet-01-prior", shared_ref)
      current = Identity.resolve("relet-01-current", shared_ref)

      assert prior.property_address == current.property_address
      assert prior.tenant_name != current.tenant_name
    end

    test "address tracks property_ref, name tracks tenancy_id (independent keys)" do
      # Same tenancy_id, different property_ref → same name, different address.
      one = Identity.resolve("t-1", "prop-a")
      two = Identity.resolve("t-1", "prop-b")

      assert one.tenant_name == two.tenant_name
      assert one.property_address != two.property_address
    end
  end

  describe "RNG hygiene" do
    test "restores the caller's prior :rand state — no deterministic leak" do
      # Seed the process, draw a value, then interleave a resolve and draw again: the
      # second draw must equal the value the stream would have produced with no resolve
      # in between, proving resolve restored the prior :rand state.
      :rand.seed(:exsss, {1, 2, 3})
      _ = :rand.uniform(1_000_000)
      expected_next = :rand.uniform(1_000_000)

      :rand.seed(:exsss, {1, 2, 3})
      _ = :rand.uniform(1_000_000)
      _ = Identity.resolve("relet-01-current", "prop-relet-01")
      actual_next = :rand.uniform(1_000_000)

      assert actual_next == expected_next
    end

    test "tolerates an unseeded process (exported seed :undefined)" do
      # In a fresh process with no prior :rand state, resolve must not crash on restore.
      task =
        Task.async(fn ->
          assert :undefined == :rand.export_seed()
          Identity.resolve("healthy-01", "prop-healthy-01")
        end)

      assert %{tenant_name: name} = Task.await(task)
      assert is_binary(name)
    end
  end
end
