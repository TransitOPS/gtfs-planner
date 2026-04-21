defmodule GtfsPlannerWeb.Api.V1.SyncController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.Pathway

  @editable_fields ~w(traversal_time stair_count min_width signposted_as reversed_signposted_as field_notes field_completed_at)a

  @doc "POST /api/v1/versions/:version_id/stations/:station_id/sync"
  def create(conn, %{"version_id" => _version_id, "station_id" => _station_id, "pathways" => pathway_updates}) do
    org_id = conn.assigns[:current_organization_id]

    results =
      Enum.reduce(pathway_updates, %{synced: 0, errors: []}, fn update, acc ->
        raw_id = update["id"]

        case Ecto.UUID.cast(raw_id) do
          {:ok, pathway_id} ->
            case Repo.get_by(Pathway, id: pathway_id, organization_id: org_id) do
              nil ->
                %{acc | errors: [%{id: raw_id, code: "not_found", message: "Pathway not found."} | acc.errors]}

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
                    %{acc | errors: [%{id: raw_id, code: "validation_error", message: "Failed to update pathway."} | acc.errors]}
                end
            end

          :error ->
            %{acc | errors: [%{id: raw_id, code: "invalid_id", message: "Pathway id must be a valid UUID."} | acc.errors]}
        end
      end)

    response = %{
      data: %{
        synced_count: results.synced,
        synced_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
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
