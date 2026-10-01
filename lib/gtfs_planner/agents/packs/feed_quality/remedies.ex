defmodule GtfsPlanner.Agents.Packs.FeedQuality.Remedies do
  @moduledoc """
  The code-owned navigation allowlist for one validation finding.

  This is a navigation list, not a repair framework. There is no correction
  operation, no replacement value and no patch API: the only thing a finding can
  be handed is a link to a current record the person already edits natively
  (AC-11). `list/0` therefore reports an empty correction list beside the
  navigation it can offer, so a caller asking what can be fixed learns that
  nothing here fixes anything and that navigation is what is available.

  `inspect/3` and `prepare/4` both read through
  `GtfsPlanner.Validations.Evidence.locate/3`, which resolves the run inside the
  scope and resolves each natural key against current records with a bounded
  duplicate check. Neither returns `{:prepared, _}`: there is no prepared edit
  command in this module, and `prepare/4` additionally requires the caller's
  explicit request, so a helper's own interest in a finding can never stand in
  for the person's.

  Nothing here writes. An unresolved finding keeps its stored context and the
  reason it names no record, which is what the person is shown.
  """

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Validations.Evidence

  @typedoc "One navigation a finding can hand back, and nothing else."
  @type navigation :: %{kind: String.t(), id: String.t(), label: String.t() | nil}

  @doc """
  Returns the correction operations this slice offers, and whether it can
  navigate at all.

  The correction list is empty by design, not by absence: the answer to "what can
  the helper fix for me" is stated as none, beside the navigation it can offer.
  """
  @spec list() :: %{corrections: [], navigation: boolean()}
  def list do
    %{corrections: [], navigation: true}
  end

  @doc """
  Returns the current records one finding names, as navigation only.

  `run_ref` and `instance_ref` are the server's own references: both are
  resolved inside the scope, so a foreign, absent or stale reference is refused
  here rather than described.
  """
  @spec inspect(Scope.t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def inspect(%Scope{} = scope, run_ref, instance_ref) do
    case Evidence.locate(scope, run_ref, instance_ref) do
      {:ok, location} -> {:ok, navigation(location)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the same navigation, but only for an explicitly requested finding.

  `requested?` must be `true` from the person's own request. There is no
  prepared form: an inspection target that resolved is a link to open, and one
  that did not is an explicit unavailable with the stored context beside it.
  """
  @spec prepare(Scope.t(), String.t(), String.t(), boolean()) ::
          {:ok, map()} | {:error, atom()}
  def prepare(%Scope{} = scope, run_ref, instance_ref, true),
    do: inspect(scope, run_ref, instance_ref)

  def prepare(%Scope{}, _run_ref, _instance_ref, false), do: {:error, :not_requested}
  def prepare(_scope, _run_ref, _instance_ref, _requested), do: {:error, :invalid_arguments}

  # Only what a host may turn into a link travels, so a caller cannot read the
  # stored context of a foreign row through this module, and the findings a
  # person already has stay where they were read.
  defp navigation(location) do
    %{
      targets: Enum.map(location.targets, &navigation_entry/1),
      unresolved: location.unresolved,
      navigable: location.targets != []
    }
  end

  defp navigation_entry(target),
    do: %{kind: target.kind, id: target.id, label: target.label}
end
