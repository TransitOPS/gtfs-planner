defmodule GtfsPlanner.ChangesetHelpers do
  @moduledoc """
  Shared changeset normalization helpers applied at the persistence boundary.
  """

  import Ecto.Changeset

  @spec trim_string_fields(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  def trim_string_fields(changeset, opts \\ []) do
    except = Keyword.get(opts, :except, [])

    Enum.reduce(changeset.types, changeset, fn
      {field, :string}, acc ->
        if field in except, do: acc, else: update_change(acc, field, &trim/1)

      _other, acc ->
        acc
    end)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
