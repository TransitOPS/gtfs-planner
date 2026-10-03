defmodule GtfsPlanner.Gtfs.RoutePatterns.LabelRules do
  @moduledoc """
  Decides whether one pattern may name another as its label owner, and is the
  only place that decides it.

  A label pair is a child pointing at an owner. The pair is consistent when the
  child and the owner share organization, version, route and `direction_id`,
  and when the owner itself carries no label, which keeps the label tree one
  level deep and stops a chain of owners from forming.

  The module is pure: it reads only the scope and label keys of the two
  patterns and never reaches for the database. The callers hold the locks and
  resolve the owner, so the rule stays a decision rather than a lookup. The
  `label_pattern_id IS NULL OR label_pattern_id <> route_pattern_id` check constraint in the
  database is the backstop for a self-reference; every other rule is only
  enforced here.
  """

  alias GtfsPlanner.Gtfs.RoutePattern

  @typedoc "The rule a child-owner pair broke."
  @type violation :: :label_scope | :label_direction | :label_depth

  @doc """
  Returns `:ok` when `child` may name `owner` as its label owner.

  A missing owner is out of scope rather than merely unknown: a child always
  names a pattern of its own route, so a `nil` owner can never be the one it
  meant. Scope is checked before direction because a different route is the
  larger mistake, and an owner that already carries a label is refused last, so
  a mismatched pair is reported for what it is.
  """
  @spec validate(RoutePattern.t(), RoutePattern.t() | nil) :: :ok | {:error, violation()}
  def validate(child, owner)

  def validate(%RoutePattern{} = child, %RoutePattern{} = owner) do
    cond do
      not same_scope?(child, owner) -> {:error, :label_scope}
      child.direction_id != owner.direction_id -> {:error, :label_direction}
      not is_nil(owner.label_pattern_id) -> {:error, :label_depth}
      true -> :ok
    end
  end

  def validate(%RoutePattern{}, nil), do: {:error, :label_scope}

  defp same_scope?(child, owner) do
    child.organization_id == owner.organization_id and
      child.gtfs_version_id == owner.gtfs_version_id and
      child.route_id == owner.route_id
  end
end
