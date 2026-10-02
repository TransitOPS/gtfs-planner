defmodule GtfsPlanner.ChangesetHelpers do
  @moduledoc """
  Shared changeset normalization helpers applied at the persistence boundary.
  """

  import Ecto.Changeset

  alias GtfsPlanner.Values

  @http_url_message "must be a full web address starting with https:// or http://"
  @email_message "must be an email address, such as data@example.com"
  @email_format ~r/^[^\s]+@[^\s]+$/

  @doc """
  Trims every changed `:string` field and nils a blank result.

  Requires a prior default `cast/4`: Ecto's default `empty_values` already turn a
  whitespace-only string into `nil`, so this helper only sees `nil` or a non-blank
  binary for a cast field.
  """
  @spec trim_string_fields(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  def trim_string_fields(changeset, opts \\ []) do
    except = Keyword.get(opts, :except, [])

    Enum.reduce(changeset.types, changeset, fn
      {field, :string}, acc ->
        if field in except, do: acc, else: update_change(acc, field, &Values.presence/1)

      _other, acc ->
        acc
    end)
  end

  @doc """
  Validates a changed field holds an absolute web address with a host.

  Accepts only `http` and `https` schemes. Unchanged fields and blank changes produce no
  error, so a cleared optional field is left to `validate_required/2` where it is required.
  """
  @spec validate_http_url(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_http_url(changeset, field) do
    validate_change(changeset, field, fn _field, value ->
      if Values.blank?(value) or http_url?(value), do: [], else: [{field, @http_url_message}]
    end)
  end

  @doc """
  Validates a changed field against `~r/^[^\s]+@[^\s]+$/`, the pattern
  `GtfsPlanner.Accounts.User` uses, with the editor-facing message.

  Unchanged fields and blank changes produce no error.
  """
  @spec validate_email_address(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_email_address(changeset, field) do
    validate_change(changeset, field, fn _field, value ->
      if Values.blank?(value) or email_address?(value), do: [], else: [{field, @email_message}]
    end)
  end

  defp http_url?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host}} when is_binary(scheme) and is_binary(host) ->
        host != "" and String.downcase(scheme) in ["http", "https"]

      _other ->
        false
    end
  end

  defp http_url?(_value), do: false

  defp email_address?(value) when is_binary(value), do: Regex.match?(@email_format, value)
  defp email_address?(_value), do: false
end
