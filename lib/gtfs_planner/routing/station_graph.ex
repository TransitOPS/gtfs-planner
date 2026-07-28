defmodule GtfsPlanner.Routing.StationGraph do
  @moduledoc """
  Opaque handle holding the dual walking/wheelchair graphs for a station snapshot.
  """

  alias GtfsPlanner.Routing.Diagnostic

  @type t :: %__MODULE__{
          walking_graph: PathwaysRouter.Graph.t(),
          wheelchair_graph: PathwaysRouter.Graph.t(),
          diagnostics: [Diagnostic.t()],
          element_ids: MapSet.t(String.t()),
          pathway_count: non_neg_integer()
        }

  defstruct [:walking_graph, :wheelchair_graph, :element_ids, :pathway_count, diagnostics: []]
end
