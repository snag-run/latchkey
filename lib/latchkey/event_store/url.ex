defmodule Latchkey.EventStore.Url do
  @moduledoc """
  Derives the Commanded EventStore connection URL from `DATABASE_URL`, guarding it
  against a pooled (PgBouncer) endpoint.

  The EventStore delivers appended events to projectors (the Arrears projector, the
  simulation sweep worker) over Postgres LISTEN/NOTIFY (ADR 0003). A
  *transaction-pooled* endpoint — Neon's `-pooler` host — hands each statement a
  different backend, so a LISTEN cannot be held: projectors never ack, and
  `consistency: :strong` dispatches hang and time out. Migrations still succeed on
  the pooler, so the deploy looks healthy right up until events stop flowing.

  This is a silent, hard-to-diagnose failure, so we fail loudly at boot instead of
  limping along. The EventStore must reach Postgres over a *direct* endpoint.
  """

  @doc """
  Returns the EventStore URL derived from `database_url`: the same URL with its
  query string stripped (EventStore's parser rejects unknown params such as Neon's
  `sslmode`).

  Raises when the host is a pooled (PgBouncer) endpoint, since LISTEN/NOTIFY
  projector delivery silently dies there.
  """
  @spec derive!(String.t()) :: String.t()
  def derive!(database_url) when is_binary(database_url) do
    uri = URI.parse(database_url)

    if pooled?(uri.host) do
      raise """
      DATABASE_URL points at a pooled (PgBouncer) endpoint (host: #{uri.host}).

      The Commanded EventStore relies on Postgres LISTEN/NOTIFY to deliver events
      to projectors, and transaction pooling cannot hold a LISTEN — projectors
      would never ack and `consistency: :strong` dispatches would hang and time
      out, even though migrations pass.

      Point the EventStore at Neon's *direct* endpoint (the host without the
      `-pooler` suffix). The Repo may keep using the pooled URL.
      """
    end

    URI.to_string(%{uri | query: nil})
  end

  @doc """
  Whether `host` is a pooled (PgBouncer) endpoint that cannot hold a LISTEN.

  Neon exposes pooling on a dedicated hostname carrying a `-pooler` suffix (e.g.
  `ep-cool-name-123456-pooler.us-east-2.aws.neon.tech`).
  """
  @spec pooled?(String.t() | nil) :: boolean()
  def pooled?(nil), do: false
  def pooled?(host) when is_binary(host), do: String.contains?(host, "-pooler")
end
