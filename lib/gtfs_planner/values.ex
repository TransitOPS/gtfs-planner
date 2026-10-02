defmodule GtfsPlanner.Values do
  @moduledoc """
  Canonical blank, presence, identifier and number helpers.

  Callers alias this module and call it qualified, so a module that keeps a local helper
  with different behavior does not collide with these names.
  """

  @doc """
  Returns true for `nil` and for a binary that is empty after `String.trim/1`.

  Every other value counts as present, including `0`, `false` and `[]`.
  """
  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(_value), do: false

  @doc """
  Returns the negation of `blank?/1`.
  """
  @spec present?(term()) :: boolean()
  def present?(value), do: not blank?(value)

  @doc """
  Returns the trimmed binary, or `nil` when the value is blank or not a binary.

  A missing value is not distinguished from a blank one.
  """
  @spec presence(term()) :: String.t() | nil
  def presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def presence(_value), do: nil

  @doc """
  Returns true when the value is a binary `Ecto.UUID.cast/1` accepts.

  Uppercase hex is accepted, as is a raw 16-byte binary, because
  `Ecto.UUID.cast/1` accepts both.
  """
  @spec uuid?(term()) :: boolean()
  def uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  def uuid?(_value), do: false

  @doc """
  Returns the float value of a `Decimal`, integer or float, and `nil` otherwise.
  """
  @spec to_float(term()) :: float() | nil
  def to_float(%Decimal{} = value), do: Decimal.to_float(value)
  def to_float(value) when is_integer(value), do: value / 1
  def to_float(value) when is_float(value), do: value
  def to_float(_value), do: nil

  @doc """
  Returns the value's positive integer, or `default`.

  A binary counts only when `Integer.parse/1` consumes all of it and the result is greater
  than zero, so `"2x"`, `"0"` and `""` return `default`.
  """
  @spec positive_integer(term(), default) :: pos_integer() | default when default: term()
  def positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  def positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> default
    end
  end

  def positive_integer(_value, default), do: default

  @doc """
  Puts `value` into `map` under `key` when the value is present; otherwise returns `map`.

  `[]` and `0` are present, so they are put.
  """
  @spec put_present(map(), term(), term()) :: map()
  def put_present(map, key, value) do
    if present?(value), do: Map.put(map, key, value), else: map
  end
end
