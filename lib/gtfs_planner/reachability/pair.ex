defmodule GtfsPlanner.Reachability.Pair do
  @moduledoc """
  A single origin/destination pair in a reachability battery.
  """

  @type kind :: :entry | :egress | :transfer
  @type mode :: :walking | :wheelchair

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          kind: kind(),
          mode: mode(),
          from_stop_id: String.t(),
          from_stop_name: String.t() | nil,
          to_stop_id: String.t(),
          to_stop_name: String.t() | nil
        }

  defstruct [:index, :kind, :mode, :from_stop_id, :from_stop_name, :to_stop_id, :to_stop_name]
end
