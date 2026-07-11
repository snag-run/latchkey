defmodule Spike.AshEvents.Event do
  @moduledoc """
  Append-only event log, one row per event. Optimistic concurrency is the unique
  identity on `(stream_id, sequence)`: two writers that both read version N and
  try to append sequence N+1 collide — one create fails the unique constraint.
  """
  use Ash.Resource,
    domain: Spike.AshEvents,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "spike_ash_events"
    repo Latchkey.Repo
  end

  actions do
    defaults [:read]

    create :append do
      accept [:stream_id, :sequence, :type, :data]
    end

    read :for_stream do
      argument :stream_id, :string, allow_nil?: false
      filter expr(stream_id == ^arg(:stream_id))
      prepare build(sort: [sequence: :asc])
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :stream_id, :string, allow_nil?: false, public?: true
    attribute :sequence, :integer, allow_nil?: false, public?: true
    attribute :type, :atom, allow_nil?: false, public?: true
    attribute :data, :map, allow_nil?: false, default: %{}, public?: true
    create_timestamp :inserted_at
  end

  identities do
    # This is the whole concurrency control.
    identity :stream_sequence, [:stream_id, :sequence]
  end
end
