defmodule GtfsPlannerWeb.SessionRevocations do
  @moduledoc """
  Disconnects browser sessions after membership changes revoke their tokens.
  """

  use GenServer

  alias GtfsPlannerWeb.UserAuth

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "session_revocations")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:session_tokens_revoked, digests}, state) do
    :ok = UserAuth.disconnect_session_digests(digests)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
