defmodule GtfsPlannerWeb.Api.V1.SyncController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.Pathway

  @editable_fields ~w(traversal_time stair_count min_width signposted_as reversed_signposted_as notes field_complete completed_at)a

  @doc "POST /api/v1/versions/:version_id/stations/:station_id/sync"
  def create(conn, %{"version_id" => _version_id, "station_id" => _station_id, "pathways" => pathway_updates}) do
    results =
      Enum.reduce(pathway_updates, %{synced: 0, errors: []}, fn update, acc ->
        pathway_id = update["id"]

        case Repo.get(Pathway, pathway_id) do
          nil ->
            %{acc | errors: [%{id: pathway_id, code: "not_found", message: "Pathway no longer exists."} | acc.errors]}

          pathway ->
            attrs =
              update
              |> Map.take(Enum.map(@editable_fields, &Atom.to_string/1))
              |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

            changeset = Pathway.changeset(pathway, attrs)

            case Repo.update(changeset) do
              {:ok, _} ->
                %{acc | synced: acc.synced + 1}

              {:error, _changeset} ->
                %{acc | errors: [%{id: pathway_id, code: "validation_error", message: "Failed to update pathway."} | acc.errors]}
            end
        end
      end)

    response = %{
      data: %{
        synced_count: results.synced,
        synced_at: DateTime.utc_now()
      }
    }

    response =
      if results.errors != [] do
        put_in(response, [:data, :errors], Enum.reverse(results.errors))
      else
        response
      end

    json(conn, response)
  end

  def create(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: %{code: "bad_request", message: "Request must include a 'pathways' array."}})
  end
end
