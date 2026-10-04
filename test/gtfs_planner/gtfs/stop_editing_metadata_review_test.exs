defmodule GtfsPlanner.Gtfs.StopEditingMetadataReviewTest do
  @moduledoc """
  Merge evidence (EV-10) for `StopEditing.review_metadata_batch/2`.

  Expected rows are hand-written from the fixture: directional twins `S410`
  ("Main St @ St Paul EB") and `S411` ("... WB") that must never merge, a third stop
  `S500`, and a station-less stop `S600` with no coordinates. Validation is the
  native `Stop.editor_changeset/2`'s, so a bad URL or a missing coordinate pair reads
  exactly as the single-stop editor would say it.
  """

  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopEditing

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: actor.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    stop = fn id, name, extra ->
      stop_fixture(
        organization.id,
        version.id,
        Map.merge(
          %{
            stop_id: id,
            stop_name: name,
            stop_code: String.trim_leading(id, "S"),
            stop_desc: "Stored description of #{id}",
            stop_url: "https://example.org/#{id}",
            stop_lat: Decimal.from_float(44.62),
            stop_lon: Decimal.from_float(-124.05)
          },
          extra
        )
      )
    end

    stops = %{
      "S410" => stop.("S410", "Main St @ St Paul EB", %{}),
      "S411" => stop.("S411", "Main St @ St Paul WB", %{}),
      "S500" => stop.("S500", "Oak Ave", %{})
    }

    %{organization: organization, version: version, audit: audit, stops: stops}
  end

  test "directional twins are separate rows keyed by their own UUIDs", context do
    %{"S410" => eb, "S411" => wb} = context.stops

    assert {:ok, review} =
             StopEditing.review_metadata_batch(
               [
                 row(wb, %{"stop_name" => "Main St & St Paul (westbound)"}),
                 row(eb, %{"stop_name" => "Main St & St Paul (eastbound)"})
               ],
               context.audit
             )

    assert {review.changed, review.unchanged, review.valid?, review.warnings} == {2, 0, true, []}
    assert Enum.map(review.rows, & &1.stop_id) == ["S410", "S411"]
    assert Enum.map(review.rows, & &1.status) == [:changed, :changed]
    assert Enum.map(review.rows, & &1.stop_uuid) == [eb.id, wb.id]

    [eb_row, wb_row] = review.rows
    assert eb_row.old["stop_name"] == "Main St @ St Paul EB"
    assert eb_row.new["stop_name"] == "Main St & St Paul (eastbound)"
    assert wb_row.old["stop_name"] == "Main St @ St Paul WB"
    assert wb_row.new["stop_name"] == "Main St & St Paul (westbound)"

    # Every other field of each row reads as stored.
    for {row, stop} <- [{eb_row, eb}, {wb_row, wb}] do
      assert row.changed_fields == ["stop_name"]
      assert row.errors == %{}
      assert row.location_type == 0

      assert Map.drop(row.new, ["stop_name"]) ==
               %{
                 "stop_code" => stop.stop_code,
                 "stop_desc" => stop.stop_desc,
                 "stop_url" => stop.stop_url
               }
    end
  end

  test "refuses anything but the four fields, malformed batches and over-size batches",
       context do
    %{"S410" => eb, "S411" => wb} = context.stops
    ok_row = row(eb, %{"stop_name" => "Fine"})

    for field <- ~w(stop_id stop_lat wheelchair_boarding parent_station zone_id location_type) do
      assert StopEditing.review_metadata_batch([row(eb, %{field => "1"})], context.audit) ==
               {:error, :invalid_input},
             field
    end

    for bad <- [
          row(eb, %{}),
          row(eb, %{"stop_name" => "  "}),
          row(eb, %{"stop_name" => 410}),
          row(eb, %{stop_name: "Atom keys are not the contract"}),
          %{stop_uuid: "not-a-uuid", changes: %{"stop_name" => "X"}},
          %{changes: %{"stop_name" => "X"}}
        ] do
      assert StopEditing.review_metadata_batch([ok_row, bad], context.audit) ==
               {:error, :invalid_input},
             inspect(bad)
    end

    assert StopEditing.review_metadata_batch([], context.audit) == {:error, :invalid_input}
    assert StopEditing.review_metadata_batch(:rows, context.audit) == {:error, :invalid_input}

    assert StopEditing.review_metadata_batch(
             [ok_row, row(eb, %{"stop_code" => "9"})],
             context.audit
           ) ==
             {:error, :invalid_input}

    too_many =
      for _ <- 1..101, do: %{stop_uuid: Ecto.UUID.generate(), changes: %{"stop_name" => "X"}}

    assert StopEditing.review_metadata_batch(too_many, context.audit) == {:error, :too_many}

    # Exactly 100 is within the ceiling; unknown UUIDs then fail as a whole.
    hundred = Enum.take(too_many, 100)
    assert StopEditing.review_metadata_batch(hundred, context.audit) == {:error, :not_found}

    other_version = gtfs_version_fixture(context.organization.id)
    foreign = stop_fixture(context.organization.id, other_version.id, %{stop_id: "S411"})

    assert StopEditing.review_metadata_batch(
             [
               ok_row,
               row(wb, %{"stop_name" => "Also fine"}),
               row(foreign, %{"stop_name" => "X"})
             ],
             context.audit
           ) == {:error, :not_found}
  end

  test "native validation marks a row invalid without disturbing the others", context do
    %{"S410" => eb, "S411" => wb} = context.stops

    assert {:ok, review} =
             StopEditing.review_metadata_batch(
               [
                 row(eb, %{"stop_name" => "Fine name", "stop_url" => "http://example.org/stop"}),
                 row(wb, %{"stop_url" => "javascript:alert(1)"})
               ],
               context.audit
             )

    [fine, bad] = review.rows
    assert fine.status == :changed
    assert fine.new["stop_url"] == "http://example.org/stop"
    assert bad.status == :invalid
    assert [message] = bad.errors["stop_url"]
    assert message =~ "http"
    assert {review.valid?, review.changed, review.unchanged} == {false, 1, 0}
  end

  test "a located stop with no coordinates is refused as the native editor refuses it",
       context do
    unplaced = stop_fixture(context.organization.id, context.version.id, %{stop_id: "S600"})

    Repo.update_all(from(s in Stop, where: s.id == ^unplaced.id),
      set: [stop_lat: nil, stop_lon: nil]
    )

    assert {:ok, review} =
             StopEditing.review_metadata_batch(
               [row(unplaced, %{"stop_name" => "Placed later"})],
               context.audit
             )

    assert [%{status: :invalid, errors: errors}] = review.rows
    assert Map.keys(errors) |> Enum.sort() == ["stop_lat", "stop_lon"]
    assert review.valid? == false
  end

  test "a value equal after trimming is unchanged and only changed fields are listed",
       context do
    %{"S410" => eb, "S500" => oak} = context.stops

    assert {:ok, review} =
             StopEditing.review_metadata_batch(
               [
                 row(oak, %{"stop_name" => "  Oak Ave  "}),
                 row(eb, %{"stop_name" => " Main St @ St Paul EB", "stop_code" => "410-A"})
               ],
               context.audit
             )

    assert {review.changed, review.unchanged, review.valid?} == {1, 1, true}
    [eb_row, oak_row] = review.rows

    assert {eb_row.stop_id, eb_row.status, eb_row.changed_fields} ==
             {"S410", :changed, ["stop_code"]}

    assert {oak_row.stop_id, oak_row.status, oak_row.changed_fields} == {"S500", :unchanged, []}
    assert eb_row.new["stop_name"] == "Main St @ St Paul EB"
  end

  test "duplicate names warn and never merge", context do
    %{"S410" => eb, "S411" => wb, "S500" => oak} = context.stops

    other_stop =
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "S700",
        stop_name: "Elm Street"
      })

    assert {:ok, review} =
             StopEditing.review_metadata_batch(
               [
                 # Equal ignoring case to a stop outside the batch.
                 row(oak, %{"stop_name" => "ELM STREET"}),
                 # Two rows renamed to the same name warn each other.
                 row(eb, %{"stop_name" => "St Paul Terminal"}),
                 row(wb, %{"stop_name" => " st paul terminal "})
               ],
               context.audit
             )

    assert review.warnings |> Enum.sort_by(& &1.stop_uuid) ==
             Enum.sort_by(
               [
                 %{
                   kind: :duplicate_name,
                   stop_uuid: oak.id,
                   name: "ELM STREET",
                   others: ["S700"]
                 },
                 %{
                   kind: :duplicate_name,
                   stop_uuid: eb.id,
                   name: "St Paul Terminal",
                   others: ["S411"]
                 },
                 %{
                   kind: :duplicate_name,
                   stop_uuid: wb.id,
                   name: "st paul terminal",
                   others: ["S410"]
                 }
               ],
               & &1.stop_uuid
             )

    assert review.valid? == true
    assert Repo.get!(Stop, other_stop.id).stop_name == "Elm Street"

    # A stop's own current name never warns, even when only its case changes, and a
    # swap between two reviewed stops is not a duplicate.
    assert {:ok, %{warnings: []}} =
             StopEditing.review_metadata_batch(
               [
                 row(oak, %{"stop_name" => "OAK AVE"}),
                 row(eb, %{"stop_name" => "Main St @ St Paul WB"}),
                 row(wb, %{"stop_name" => "Main St @ St Paul EB"})
               ],
               context.audit
             )
  end

  test "writes nothing, is repeatable, notices a same-second rename and refuses non-editors",
       context do
    %{"S410" => eb, "S411" => wb} = context.stops
    rows = [row(eb, %{"stop_name" => "One"}), row(wb, %{"stop_name" => "Two"})]
    before = {stamps(), Repo.aggregate(ChangeLog, :count)}

    assert {:ok, first} = StopEditing.review_metadata_batch(rows, context.audit)
    assert {:ok, again} = StopEditing.review_metadata_batch(Enum.reverse(rows), context.audit)

    assert String.length(first.fingerprint) == 64
    assert first.fingerprint == again.fingerprint
    assert {stamps(), Repo.aggregate(ChangeLog, :count)} == before

    # A committed rename inside the same second leaves `updated_at` as it was, and the
    # fingerprint still changes because the stored content is part of it.
    Repo.update_all(from(s in Stop, where: s.id == ^eb.id), set: [stop_name: "Renamed elsewhere"])
    assert {:ok, moved} = StopEditing.review_metadata_batch(rows, context.audit)
    assert moved.fingerprint != first.fingerprint

    stranger = user_fixture()
    stranger_audit = %{context.audit | actor_id: stranger.id, actor_email: stranger.email}

    assert StopEditing.review_metadata_batch(rows, stranger_audit) == {:error, :forbidden}
  end

  defp row(stop, changes), do: %{stop_uuid: stop.id, changes: changes}

  defp stamps do
    Repo.all(
      from(s in Stop,
        order_by: s.id,
        select: {s.id, s.updated_at, s.stop_name, s.stop_code, s.stop_desc, s.stop_url}
      )
    )
  end
end
