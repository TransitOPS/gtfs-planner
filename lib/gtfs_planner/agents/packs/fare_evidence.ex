defmodule GtfsPlanner.Agents.Packs.FareEvidence do
  @moduledoc """
  Builds the server evidence the two fare packs return beside a tool result.

  Both fare packs describe an answer the same way: the exact count, the
  completeness, a content digest, the resolved scope and typed references. Each
  existing pack builds its evidence privately because its shape differs; the two
  fare packs share this one builder because their shape does not. Evidence is
  built by the pack from the same read as the result it describes and never
  carries model output.
  """

  alias GtfsPlanner.Agents.Pack
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Fares.Money

  @doc """
  Assembles one evidence map.

  Required fields: `:kind`, `:title`, `:total`, `:total_label`, `:source_ref` and
  `:digest` (a lowercase hex SHA-256, see `digest/1`). Optional fields default to a
  complete answer with no facts, exclusions or resources. The scope records the
  organization, version and `"version:<id>"` identity the read ran under, which the
  panel re-checks before it shows a card.
  """
  @spec build(Scope.t(), map()) :: Pack.evidence()
  def build(
        %Scope{} = scope,
        %{
          kind: _,
          title: _,
          total: _,
          total_label: _,
          source_ref: _,
          digest: _
        } = fields
      ) do
    %{
      kind: fields.kind,
      title: fields.title,
      total: fields.total,
      total_label: fields.total_label,
      completeness: Map.get(fields, :completeness, :complete),
      completeness_reason: Map.get(fields, :completeness_reason),
      facts: Map.get(fields, :facts, []),
      source_ref: fields.source_ref,
      digest: fields.digest,
      source_revision: nil,
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      exclusions: Map.get(fields, :exclusions, []),
      resources: Map.get(fields, :resources, [])
    }
  end

  @doc """
  A stored amount as the decimal string a person reads: the currency's minor units
  when the amount fits them exactly (`1.50`), otherwise the exact digits, so a
  rounded figure never stands in for an amount it is not.
  """
  @spec amount_string(Decimal.t() | nil, String.t()) :: String.t() | nil
  def amount_string(nil, _currency), do: nil

  def amount_string(%Decimal{} = amount, currency) do
    rounded = Decimal.round(amount, Money.minor_units(currency))
    exact = if Decimal.equal?(rounded, amount), do: rounded, else: amount
    Decimal.to_string(exact, :normal)
  end

  @doc "The lowercase hex SHA-256 of the canonical encoding of `term`."
  @spec digest(term()) :: String.t()
  def digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  defp identity_label(%Scope{} = scope) do
    case Scope.identity(scope) do
      {kind, id} -> "#{kind}:#{id}"
      nil -> nil
    end
  end
end
