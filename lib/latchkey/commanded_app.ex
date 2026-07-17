defmodule Latchkey.CommandedApp do
  @moduledoc """
  The Commanded application — hosts aggregates, routes commands, owns the
  EventStore connection. Dispatch commands through `Latchkey.CommandedApp.dispatch/2`.

  ## Surfacing strong-consistency dispatch failures (issue #149)

  A `consistency: :strong` dispatch waits for the read model to catch up, so it can
  return `{:error, :consistency_timeout}` when a projector never acks — most notoriously
  against a Neon `-pooler` (PgBouncer) endpoint, which can't hold the EventStore's
  LISTEN/NOTIFY, so *every* strong dispatch times out. Call sites that pattern-matched
  only `:ok` (and a business error) turned that into a bare `CaseClauseError` with no
  hint at the cause. `dispatch_strong/2` centralises the strong-consistency call and
  raises a clear, actionable error on any dispatch failure instead — never silently
  swallowing it, since the event may already have appended and left a half-seeded stream.
  """
  use Commanded.Application, otp_app: :latchkey

  router(Latchkey.Router)

  @doc """
  Dispatch `command` with `consistency: :strong`, surfacing an infrastructure dispatch
  failure (chiefly `:consistency_timeout`) as a raised, actionable error rather than
  letting it fall through to a `CaseClauseError` with no signal (issue #149).

  `:ok` returns `:ok`; a business error whose reason is listed in `expected` is returned
  as `{:error, reason}` for the caller to handle; any other `{:error, reason}` raises.
  """
  @spec dispatch_strong(struct(), [atom()]) :: :ok | {:error, atom()}
  def dispatch_strong(command, expected \\ []) do
    command
    |> dispatch(consistency: :strong)
    |> handle_strong_result(command, expected)
  end

  @doc """
  Map a strong-consistency dispatch result to `:ok`, a returned expected business error,
  or a raised actionable error — the pure seam behind `dispatch_strong/2` (issue #149).
  An error reason not in `expected` (e.g. `:consistency_timeout`) is never swallowed:
  it raises, because the event may already have appended.
  """
  @spec handle_strong_result(:ok | {:error, atom()}, struct(), [atom()]) ::
          :ok | {:error, atom()}
  def handle_strong_result(result, command, expected \\ []) do
    case result do
      :ok ->
        :ok

      {:error, reason} ->
        if reason in expected do
          {:error, reason}
        else
          raise strong_dispatch_error(command, reason)
        end
    end
  end

  defp strong_dispatch_error(command, :consistency_timeout) do
    """
    Strong-consistency dispatch of #{command_name(command)} timed out (:consistency_timeout): \
    a projector never acked within the consistency timeout. The event may already have \
    appended, so the stream may be half-seeded — drop and recreate rather than resuming.

    If pointed at Neon, confirm you're on the direct (non-pooler) endpoint: the -pooler \
    (PgBouncer) endpoint can't hold the EventStore's LISTEN/NOTIFY, so projectors never \
    ack and every consistency: :strong dispatch times out.\
    """
  end

  defp strong_dispatch_error(command, reason) do
    """
    Strong-consistency dispatch of #{command_name(command)} failed: #{inspect(reason)}. \
    The event may already have appended, so the stream may be half-seeded — drop and \
    recreate rather than resuming.\
    """
  end

  defp command_name(command) when is_struct(command) do
    command.__struct__ |> Module.split() |> List.last()
  end
end
