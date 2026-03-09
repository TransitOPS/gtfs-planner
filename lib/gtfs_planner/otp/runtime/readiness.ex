defmodule GtfsPlanner.Otp.Runtime.Readiness do
  @moduledoc """
  Polls OTP GraphQL endpoint readiness until success or timeout.
  """

  alias GtfsPlanner.Otp.Runtime.Session

  @default_ready_timeout_ms 30_000
  @default_poll_interval_ms 250

  @type timeout_issue :: %{
          reason: :ready_timeout,
          graphql_url: String.t(),
          timeout_ms: pos_integer(),
          poll_interval_ms: pos_integer(),
          last_error: term() | nil
        }

  @type issue :: timeout_issue()

  @type request_result :: :ok | {:error, term()}
  @type request_fun :: (String.t() -> request_result())

  @spec wait_until_ready(Session.t() | String.t(), keyword()) :: :ok | {:error, issue()}
  def wait_until_ready(target, opts \\ [])

  def wait_until_ready(%Session{graphql_url: graphql_url}, opts),
    do: wait_until_ready(graphql_url, opts)

  def wait_until_ready(graphql_url, opts) when is_binary(graphql_url) and is_list(opts) do
    timeout_ms =
      Keyword.get(
        opts,
        :timeout_ms,
        Application.get_env(
          :gtfs_planner,
          :otp_server_ready_timeout_ms,
          @default_ready_timeout_ms
        )
      )

    poll_interval_ms =
      Keyword.get(
        opts,
        :poll_interval_ms,
        Application.get_env(
          :gtfs_planner,
          :otp_server_ready_poll_interval_ms,
          @default_poll_interval_ms
        )
      )

    request_fun = Keyword.get(opts, :request_fun, &default_request/1)
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    monotonic_time_fun = Keyword.get(opts, :monotonic_time_fun, &System.monotonic_time/1)

    deadline_ms = monotonic_time_fun.(:millisecond) + timeout_ms

    do_wait(
      graphql_url,
      deadline_ms,
      timeout_ms,
      poll_interval_ms,
      request_fun,
      sleep_fun,
      monotonic_time_fun,
      nil
    )
  end

  defp do_wait(
         graphql_url,
         deadline_ms,
         timeout_ms,
         poll_interval_ms,
         request_fun,
         sleep_fun,
         monotonic_time_fun,
         _last_error
       ) do
    case request_fun.(graphql_url) do
      :ok ->
        :ok

      {:error, last_error} ->
        if monotonic_time_fun.(:millisecond) >= deadline_ms do
          {:error,
           %{
             reason: :ready_timeout,
             graphql_url: graphql_url,
             timeout_ms: timeout_ms,
             poll_interval_ms: poll_interval_ms,
             last_error: last_error
           }}
        else
          sleep_fun.(poll_interval_ms)

          do_wait(
            graphql_url,
            deadline_ms,
            timeout_ms,
            poll_interval_ms,
            request_fun,
            sleep_fun,
            monotonic_time_fun,
            last_error
          )
        end
    end
  end

  defp default_request(graphql_url) do
    case Req.post(url: graphql_url, json: %{query: "{__typename}"}, retry: false) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, %{reason: :unexpected_status, status: status}}

      {:error, reason} ->
        {:error, %{reason: :request_failed, details: inspect(reason)}}
    end
  end
end
