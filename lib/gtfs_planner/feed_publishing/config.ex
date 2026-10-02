defmodule GtfsPlanner.FeedPublishing.Config do
  @moduledoc """
  Optional public feed publishing settings.

  Publishing is activated by `GTFS_PUBLISH_BUCKET` and only then, together with a
  complete `GTFS_PUBLISH_ENDPOINT`, `GTFS_PUBLISH_REGION`,
  `GTFS_PUBLISH_ACCESS_KEY_ID`, `GTFS_PUBLISH_SECRET_ACCESS_KEY` and
  `GTFS_PUBLISH_PUBLIC_BASE_URL`. An absent or blank activation setting disables the
  capability quietly; incomplete or malformed settings disable it with one sanitized
  diagnostic naming the environment variables, never their values. Nothing here probes
  storage, and the mail adapter's AWS credentials are never borrowed.

  This module owns normalization. `config/runtime.exs` normalizes the boot environment
  once through `load/1` and stores the result under
  `:feed_publishing_config`, which `current/0` returns. Test configuration is compiled
  before this module exists, so it may only store a raw string-keyed settings map under
  `:feed_publishing_settings`; `current/0` normalizes that fixture on read.
  """

  require Logger

  @bucket_var "GTFS_PUBLISH_BUCKET"
  @settings [
    endpoint: "GTFS_PUBLISH_ENDPOINT",
    region: "GTFS_PUBLISH_REGION",
    access_key_id: "GTFS_PUBLISH_ACCESS_KEY_ID",
    secret_access_key: "GTFS_PUBLISH_SECRET_ACCESS_KEY",
    public_base_url: "GTFS_PUBLISH_PUBLIC_BASE_URL"
  ]

  defstruct [:bucket, :endpoint, :region, :access_key_id, :secret_access_key, :public_base_url]

  @type t :: %__MODULE__{
          bucket: String.t(),
          endpoint: URI.t(),
          region: String.t(),
          access_key_id: String.t(),
          secret_access_key: String.t(),
          public_base_url: URI.t()
        }

  @type normalized :: :disabled | {:enabled, t()}

  @doc """
  Normalizes the six publishing settings of an environment map.

  Returns `:disabled` when the activation setting is absent or blank, and also when any
  required setting is missing, blank or not an acceptable HTTPS origin.
  """
  @spec load(map()) :: normalized()
  def load(env) when is_map(env) do
    case setting(env, @bucket_var) do
      {:ok, bucket} -> enable(bucket, env)
      :blank -> :disabled
    end
  end

  @doc """
  Returns the normalized publishing configuration for the running application.
  """
  @spec current() :: normalized()
  def current do
    case Application.get_env(:gtfs_planner, :feed_publishing_config) do
      nil -> normalize(Application.get_env(:gtfs_planner, :feed_publishing_settings))
      normalized -> normalized
    end
  end

  defp enable(bucket, env) do
    required = [
      {:bucket, @bucket_var, {:ok, bucket}} | Enum.map(@settings, &setting_entry(env, &1))
    ]

    required
    |> Enum.reduce_while({:ok, []}, fn
      {key, _variable, {:ok, value}}, {:ok, acc} -> {:cont, {:ok, [{key, value} | acc]}}
      {_key, variable, :blank}, {:ok, _acc} -> {:halt, {:error, {variable, :blank}}}
    end)
    |> case do
      {:ok, values} -> validate_origins(values)
      {:error, problem} -> disable(problem)
    end
  end

  defp setting_entry(env, {key, variable}), do: {key, variable, setting(env, variable)}

  # Both origins are deployed HTTPS URLs. Userinfo would put a credential in a URL
  # the operator can read from logs, and a query or fragment would make the published
  # object key ambiguous, so neither is accepted.
  defp validate_origins(values) do
    Enum.reduce_while([:endpoint, :public_base_url], {:ok, values}, fn key, {:ok, acc} ->
      case origin(acc[key]) do
        {:ok, uri} -> {:cont, {:ok, Keyword.put(acc, key, uri)}}
        :invalid -> {:halt, {:error, {Keyword.fetch!(@settings, key), :invalid}}}
      end
    end)
    |> case do
      {:ok, values} -> {:enabled, struct!(__MODULE__, values)}
      {:error, problem} -> disable(problem)
    end
  end

  defp disable({variable, reason}) do
    Logger.warning(
      "public feed publishing is disabled: #{variable} #{describe(reason)}; " <>
        "set the complete #{@bucket_var} publishing settings to enable it"
    )

    :disabled
  end

  defp describe(:blank), do: "is missing or blank"
  defp describe(:invalid), do: "must be an absolute https URL without userinfo, query or fragment"

  defp setting(env, variable) do
    case Map.get(env, variable) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> :blank
          trimmed -> {:ok, trimmed}
        end

      _ ->
        :blank
    end
  end

  defp origin(value) do
    uri = URI.parse(value)

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      {:ok, uri}
    else
      :invalid
    end
  end

  defp normalize(nil), do: :disabled
  defp normalize(:disabled), do: :disabled
  defp normalize(%{} = settings), do: load(settings)
end
