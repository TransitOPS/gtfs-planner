defmodule GtfsPlanner.Routing.Diagnostic do
  @moduledoc """
  Application-owned, JSON-safe diagnostic converted from router diagnostics.
  """

  @type t :: %__MODULE__{
          severity: :warning | :error,
          code: atom(),
          entity_type: String.t(),
          entity_id: String.t() | nil,
          message: String.t()
        }

  defstruct [:severity, :code, :entity_type, :entity_id, :message]

  @spec from_router(PathwaysRouter.Diagnostic.t()) :: t()
  def from_router(%PathwaysRouter.Diagnostic{} = diag) do
    %__MODULE__{
      severity: diag.severity,
      code: diag.code,
      entity_type: diag.entity_type,
      entity_id: diag.entity_id,
      message: diag.message
    }
  end

  @spec to_map(t()) :: %{String.t() => String.t() | nil}
  def to_map(%__MODULE__{} = diag) do
    %{
      "severity" => Atom.to_string(diag.severity),
      "code" => Atom.to_string(diag.code),
      "entity_type" => diag.entity_type,
      "entity_id" => diag.entity_id,
      "message" => diag.message
    }
  end
end
