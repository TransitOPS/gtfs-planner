defmodule GtfsPlannerWeb.Api.V1.SyncController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Repo

  @editable_fields ~w(traversal_time stair_count min_width signposted_as reversed_signposted_as field_notes field_completed_at)a

  # from_stop_id/to_stop_id are accepted ONLY as a swap of the pathway's own
  # endpoints (the field "Reverse direction" action) — the stored pair in
  # either order. Any other value pair is rejected per-pathway with
  # `invalid_endpoints` and no fields are applied: sync can reverse a pathway,
  # never rewire one. Omitting the pair preserves the pre-existing behavior.
  # See the companion app's specs/api/sync.md.

  @doc "POST /api/v1/versions/:version_id/stations/:station_id/sync"
  def create(
        conn,
        %{
          "version_id" => version_id,
          "station_id" => station_id,
          "pathways" => pathway_updates
        } = params
      ) do
    org_id = conn.assigns[:current_organization_id]
    author_id = conn.assigns[:current_user_id]
    journal_updates = Map.get(params, "journal_entries", [])

    results =
      Enum.reduce(pathway_updates, %{synced: 0, errors: []}, fn update, acc ->
        raw_id = update["id"]

        case Ecto.UUID.cast(raw_id) do
          {:ok, pathway_id} ->
            case Repo.get_by(Pathway, id: pathway_id, organization_id: org_id) do
              nil ->
                %{
                  acc
                  | errors: [
                      %{id: raw_id, code: "not_found", message: "Pathway not found."} | acc.errors
                    ]
                }

              pathway ->
                case endpoint_attrs(update, pathway) do
                  :invalid_endpoints ->
                    %{
                      acc
                      | errors: [
                          %{
                            id: raw_id,
                            code: "invalid_endpoints",
                            message:
                              "from_stop_id/to_stop_id may only swap the pathway's own endpoints."
                          }
                          | acc.errors
                        ]
                    }

                  {:ok, endpoint_changes} ->
                    attrs =
                      update
                      |> Map.take(Enum.map(@editable_fields, &Atom.to_string/1))
                      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
                      |> Map.merge(endpoint_changes)

                    changeset = Pathway.changeset(pathway, attrs)

                    case Repo.update(changeset) do
                      {:ok, _} ->
                        %{acc | synced: acc.synced + 1}

                      {:error, _changeset} ->
                        %{
                          acc
                          | errors: [
                              %{
                                id: raw_id,
                                code: "validation_error",
                                message: "Failed to update pathway."
                              }
                              | acc.errors
                            ]
                        }
                    end
                end
            end

          :error ->
            %{
              acc
              | errors: [
                  %{id: raw_id, code: "invalid_id", message: "Pathway id must be a valid UUID."}
                  | acc.errors
                ]
            }
        end
      end)

    journal = sync_journal_entries(journal_updates, org_id, version_id, station_id, author_id)

    errors = Enum.reverse(results.errors) ++ journal.errors

    data =
      %{
        synced_count: results.synced,
        synced_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }
      |> maybe_put(:journal_synced_count, journal_updates != [], journal.synced)
      |> maybe_put(:errors, errors != [], errors)

    json(conn, %{data: data})
  end

  def create(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: %{code: "bad_request", message: "Request must include a 'pathways' array."}})
  end

  # Validates the swap-only endpoint rule. Returns {:ok, changes} where
  # `changes` is empty (pair absent, or matches stored order — a no-op) or the
  # swapped pair; :invalid_endpoints for anything else, including a partial
  # pair.
  defp endpoint_attrs(update, pathway) do
    has_from = Map.has_key?(update, "from_stop_id")
    has_to = Map.has_key?(update, "to_stop_id")

    cond do
      not has_from and not has_to ->
        {:ok, %{}}

      has_from and has_to ->
        pair = {update["from_stop_id"], update["to_stop_id"]}

        cond do
          pair == {pathway.from_stop_id, pathway.to_stop_id} ->
            {:ok, %{}}

          pair == {pathway.to_stop_id, pathway.from_stop_id} ->
            {:ok, %{from_stop_id: pathway.to_stop_id, to_stop_id: pathway.from_stop_id}}

          true ->
            :invalid_endpoints
        end

      true ->
        :invalid_endpoints
    end
  end

  defp maybe_put(map, _key, false, _value), do: map
  defp maybe_put(map, key, true, value), do: Map.put(map, key, value)

  # Upsert station-journal entries by client-generated id (idempotent). Each item
  # is independent, like the pathway loop — partial failure stays 200 with
  # per-item errors. Entries are scoped to the path's version/station and the
  # session's org/user; a request to a station outside the org fails them all.
  defp sync_journal_entries([], _org_id, _version_id, _station_id, _author_id),
    do: %{synced: 0, errors: []}

  defp sync_journal_entries(updates, org_id, version_id, station_id, author_id) do
    if valid_station?(Gtfs.get_stop(station_id), org_id, version_id) do
      updates
      |> Enum.reduce(%{synced: 0, errors: []}, fn update, acc ->
        attrs = %{
          "id" => update["id"],
          "organization_id" => org_id,
          "gtfs_version_id" => version_id,
          "station_id" => station_id,
          "author_id" => author_id,
          "target_type" => update["target_type"],
          "target_id" => update["target_id"],
          "body" => update["body"],
          "captured_at" => update["captured_at"],
          "resolved_at" => update["resolved_at"]
        }

        case Gtfs.upsert_journal_entry(attrs) do
          {:ok, _entry} ->
            %{acc | synced: acc.synced + 1}

          {:error, _changeset} ->
            %{
              acc
              | errors: [
                  %{
                    id: update["id"],
                    code: "validation_error",
                    message: "Failed to save journal entry."
                  }
                  | acc.errors
                ]
            }
        end
      end)
      |> then(fn acc -> %{acc | errors: Enum.reverse(acc.errors)} end)
    else
      %{
        synced: 0,
        errors:
          Enum.map(updates, fn u ->
            %{id: u["id"], code: "not_found", message: "Station not found."}
          end)
      }
    end
  end

  # Repeated variables enforce equality: matches only when the station's org and
  # version equal the request's. A nil station (not found) falls through to false.
  defp valid_station?(
         %{organization_id: org_id, gtfs_version_id: version_id},
         org_id,
         version_id
       ),
       do: true

  defp valid_station?(_station, _org_id, _version_id), do: false
end
