defmodule GtfsPlannerWeb.AuthForm do
  @moduledoc """
  What the signed-out password forms share: plain-language errors chosen by
  the rule that failed, the moment a field may show an error while the person
  types, and dropping the passwords from a rejected submit.

  Reset password, accept invitation and first-install setup all ask for a
  password and its confirmation, so the copy and the rules for showing it live
  here rather than in each LiveView.
  """

  import GtfsPlannerWeb.CoreComponents, only: [translate_error: 1]

  alias GtfsPlanner.Values

  # A failed submit must not return secrets to the browser: both password keys
  # (string and atom) are dropped from params and changes.
  @secret_keys ["password", "password_confirmation", :password, :password_confirmation]
  @secret_changes [:password, :password_confirmation]

  @doc """
  The sentence for a password error, chosen by the failed rule rather than by
  the changeset text. The length limits come from the changeset, so the copy
  cannot drift from the rule. `blank` is the sentence for an empty password.
  """
  @spec password_error({String.t(), keyword()}, String.t()) :: String.t()
  def password_error({_message, opts} = error, blank \\ "Enter a password.") do
    case {opts[:validation], opts[:kind]} do
      {:required, _kind} -> blank
      {:length, :min} -> "Use at least #{opts[:count]} characters."
      {:length, :max} -> "Use #{opts[:count]} characters or fewer."
      _other -> translate_error(error)
    end
  end

  @doc """
  The sentence for a confirmation error. `params` are the submitted form
  params: a blank confirmation reaches the changeset as a mismatch (the form
  always submits both keys, and Ecto reports `:required` only for an absent
  key), so the params tell the two apart.
  """
  @spec confirmation_error({String.t(), keyword()}, map() | nil) :: String.t()
  def confirmation_error({_message, opts} = error, params) do
    cond do
      opts[:validation] != :confirmation ->
        translate_error(error)

      Values.blank?((params || %{})["password_confirmation"]) ->
        "Enter the password again."

      true ->
        "Passwords don't match. Type the same password in both fields."
    end
  end

  @doc """
  The messages to show under `field` while the person types: those of a field
  that has been used, and none for one that has not. `to_message` maps each
  error to a sentence.
  """
  @spec used_errors(Phoenix.HTML.FormField.t(), (term() -> String.t())) :: [String.t()]
  def used_errors(%Phoenix.HTML.FormField{} = field, to_message) do
    if Phoenix.Component.used_input?(field), do: Enum.map(field.errors, to_message), else: []
  end

  @doc """
  Marks every empty field in validate `params` as unused, so it shows no error
  until submit. An error that appears on blur pushes the submit button down
  before a click on it lands, and the click is lost. Typing a value makes the
  field count as used again.
  """
  @spec defer_blank_errors(map()) :: map()
  def defer_blank_errors(params) when is_map(params) do
    Enum.reduce(params, params, fn
      {"_unused_" <> _field, _value}, acc -> acc
      {field, value}, acc when is_binary(value) -> mark_if_blank(acc, field, value)
      {_field, _value}, acc -> acc
    end)
  end

  defp mark_if_blank(params, field, value) do
    if Values.blank?(value), do: Map.put(params, "_unused_" <> field, ""), else: params
  end

  @doc """
  Drops both passwords from a failed-submit changeset while retaining the
  errors, the action and every non-secret value, so the form keeps its
  correction context without returning either password.
  """
  @spec sanitize_secrets(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def sanitize_secrets(%Ecto.Changeset{} = changeset) do
    %{
      changeset
      | params: changeset.params && Map.drop(changeset.params, @secret_keys),
        changes: Map.drop(changeset.changes, @secret_changes)
    }
  end
end
