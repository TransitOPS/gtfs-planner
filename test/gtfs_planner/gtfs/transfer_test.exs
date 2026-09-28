defmodule GtfsPlanner.Gtfs.TransferTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.Transfer

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{organization_id: organization.id, gtfs_version_id: gtfs_version.id}
  end

  describe "changeset/2" do
    test "accepts a type 4 transfer between two trips without stops", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      changeset =
        Transfer.changeset(%Transfer{}, %{
          transfer_type: 4,
          from_trip_id: "T1",
          to_trip_id: "T2",
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        })

      assert changeset.valid?
      assert errors_on(changeset) == %{}
    end

    test "keeps the stops of a type 5 transfer that names both trips", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      changeset =
        Transfer.changeset(%Transfer{}, %{
          transfer_type: 5,
          from_stop_id: "S1",
          to_stop_id: "S2",
          from_trip_id: "T1",
          to_trip_id: "T2",
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        })

      assert changeset.valid?
      assert changeset.changes.from_stop_id == "S1"
      assert changeset.changes.to_stop_id == "S2"
    end

    test "requires to_trip_id for a type 4 transfer", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      changeset =
        Transfer.changeset(%Transfer{}, %{
          transfer_type: 4,
          from_trip_id: "T1",
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        })

      refute changeset.valid?
      assert errors_on(changeset) == %{to_trip_id: ["can't be blank"]}
    end

    test "requires from_stop_id for a type 2 transfer", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      changeset =
        Transfer.changeset(%Transfer{}, %{
          transfer_type: 2,
          to_stop_id: "S2",
          min_transfer_time: 120,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        })

      refute changeset.valid?
      assert errors_on(changeset) == %{from_stop_id: ["can't be blank"]}
    end

    test "accepts a type 0 transfer between two stops without trips", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      changeset =
        Transfer.changeset(%Transfer{}, %{
          transfer_type: 0,
          from_stop_id: "S1",
          to_stop_id: "S2",
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        })

      assert changeset.valid?
    end

    test "requires transfer_type", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      changeset =
        Transfer.changeset(%Transfer{}, %{
          from_stop_id: "S1",
          to_stop_id: "S2",
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        })

      refute changeset.valid?
      assert errors_on(changeset) == %{transfer_type: ["can't be blank"]}
    end

    test "rejects a transfer_type outside 0..5", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      changeset =
        Transfer.changeset(%Transfer{}, %{
          transfer_type: 6,
          from_stop_id: "S1",
          to_stop_id: "S2",
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        })

      refute changeset.valid?
      assert errors_on(changeset) == %{transfer_type: ["is invalid"]}
    end
  end

  describe "editor_changeset/2" do
    test "casts only the eight GTFS fields, keeping the tenant columns and id from the struct", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      other_organization = organization_fixture()

      changeset =
        editor_draft(organization_id, gtfs_version_id, %{
          "id" => Ecto.UUID.generate(),
          "organization_id" => other_organization.id,
          "transfer_type" => "0",
          "from_stop_id" => "S1",
          "to_stop_id" => "S2"
        })

      assert changeset.valid?
      assert get_field(changeset, :organization_id) == organization_id
      assert get_field(changeset, :gtfs_version_id) == gtfs_version_id
      assert get_field(changeset, :id) == nil
    end

    test "accepts transfer types 0..3 only", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      for transfer_type <- [4, 5, 7] do
        changeset =
          editor_draft(organization_id, gtfs_version_id, %{
            "transfer_type" => to_string(transfer_type),
            "from_stop_id" => "S1",
            "to_stop_id" => "S2"
          })

        refute changeset.valid?

        assert errors_on(changeset).transfer_type == [
                 "Choose one of the four transfer types"
               ]
      end
    end

    test "requires both stops for the general types", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      attrs = %{"transfer_type" => "0", "from_stop_id" => "S1", "to_stop_id" => "S2"}

      changeset =
        editor_draft(organization_id, gtfs_version_id, Map.delete(attrs, "from_stop_id"))

      refute changeset.valid?
      assert errors_on(changeset).from_stop_id == ["Choose a stop or station"]

      changeset = editor_draft(organization_id, gtfs_version_id, Map.delete(attrs, "to_stop_id"))

      refute changeset.valid?
      assert errors_on(changeset).to_stop_id == ["Choose a stop or station"]
    end

    test "requires a whole number of seconds for type 2", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      attrs = %{"transfer_type" => "2", "from_stop_id" => "S1", "to_stop_id" => "S2"}

      for value <- [nil, -1, 2_147_483_648] do
        changeset =
          editor_draft(
            organization_id,
            gtfs_version_id,
            Map.put(attrs, "min_transfer_time", value)
          )

        refute changeset.valid?

        assert errors_on(changeset).min_transfer_time == [
                 "Enter a whole number of seconds, zero or more."
               ]
      end

      for value <- [0, 300] do
        changeset =
          editor_draft(
            organization_id,
            gtfs_version_id,
            Map.put(attrs, "min_transfer_time", value)
          )

        assert changeset.valid?
        assert get_field(changeset, :min_transfer_time) == value
      end
    end

    test "keeps no minimum time for types 0, 1 and 3", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      changeset =
        editor_draft(organization_id, gtfs_version_id, %{
          "transfer_type" => "1",
          "from_stop_id" => "S1",
          "to_stop_id" => "S2",
          "min_transfer_time" => 180
        })

      assert changeset.valid?
      assert get_field(changeset, :min_transfer_time) == nil

      stored = %Transfer{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        transfer_type: 0,
        from_stop_id: "S1",
        to_stop_id: "S2",
        min_transfer_time: 120
      }

      changeset = Transfer.editor_changeset(stored, %{"transfer_type" => "0"})

      assert changeset.valid?
      assert get_field(changeset, :min_transfer_time) == nil
    end

    test "treats a whitespace-only selector as empty", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      changeset =
        editor_draft(organization_id, gtfs_version_id, %{
          "transfer_type" => "0",
          "from_stop_id" => "S1",
          "from_route_id" => "   ",
          "to_stop_id" => "S2"
        })

      assert changeset.valid?
      assert get_field(changeset, :from_route_id) == nil
    end

    test "maps a duplicate six-field key to a changeset error without raising", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      transfer_fixture(organization_id, gtfs_version_id, %{
        from_stop_id: "S1",
        to_stop_id: "S2"
      })

      changeset =
        editor_draft(organization_id, gtfs_version_id, %{
          "transfer_type" => "2",
          "from_stop_id" => "S1",
          "to_stop_id" => "S2",
          "min_transfer_time" => 60
        })

      assert {:error, changeset} = Repo.insert(changeset)
      assert errors_on(changeset) == %{organization_id: ["has already been taken"]}
    end
  end

  describe "insert/1" do
    test "stores NULL stops for a type 4 transfer between two trips", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      assert {:ok, transfer} =
               insert_transfer(%{
                 transfer_type: 4,
                 from_trip_id: "T1",
                 to_trip_id: "T2",
                 organization_id: organization_id,
                 gtfs_version_id: gtfs_version_id
               })

      assert transfer.from_stop_id == nil
      assert transfer.to_stop_id == nil
      assert transfer.from_trip_id == "T1"
      assert transfer.to_trip_id == "T2"
    end

    test "returns a changeset error for a duplicate stopless type 4 key", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      attrs = %{
        transfer_type: 4,
        from_trip_id: "T1",
        to_trip_id: "T2",
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      }

      assert {:ok, _transfer} = insert_transfer(attrs)
      assert {:error, changeset} = insert_transfer(attrs)
      assert errors_on(changeset) == %{organization_id: ["has already been taken"]}
    end

    test "returns a changeset error for a duplicate stop-only type 0 key", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      # Every route and trip column stays NULL, so the second row repeats all six
      # key columns with NULL equal to NULL.
      attrs = %{
        transfer_type: 0,
        from_stop_id: "S1",
        to_stop_id: "S2",
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      }

      assert {:ok, _transfer} = insert_transfer(attrs)
      assert {:error, changeset} = insert_transfer(attrs)
      assert errors_on(changeset) == %{organization_id: ["has already been taken"]}
    end

    test "stores the same stopless key in a second version of the organization", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      other_version = gtfs_version_fixture(organization_id)

      attrs = %{
        transfer_type: 4,
        from_trip_id: "T1",
        to_trip_id: "T2",
        organization_id: organization_id
      }

      assert {:ok, transfer} = insert_transfer(Map.put(attrs, :gtfs_version_id, gtfs_version_id))

      assert {:ok, other_transfer} =
               insert_transfer(Map.put(attrs, :gtfs_version_id, other_version.id))

      assert transfer.gtfs_version_id == gtfs_version_id
      assert other_transfer.gtfs_version_id == other_version.id
    end
  end

  describe "transfer_fixture/3" do
    test "inserts a stop-only transfer from the transfer_type 0 default", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      transfer =
        transfer_fixture(organization_id, gtfs_version_id, %{
          from_stop_id: "S1",
          to_stop_id: "S2"
        })

      assert is_binary(transfer.id)
      assert transfer.organization_id == organization_id
      assert transfer.gtfs_version_id == gtfs_version_id
      assert transfer.transfer_type == 0
      assert transfer.from_stop_id == "S1"
      assert transfer.to_stop_id == "S2"
    end

    test "inserts a stopless in-seat transfer from the given attrs", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      transfer =
        transfer_fixture(organization_id, gtfs_version_id, %{
          transfer_type: 4,
          from_trip_id: "T1",
          to_trip_id: "T2"
        })

      assert transfer.transfer_type == 4
      assert transfer.from_trip_id == "T1"
      assert transfer.to_trip_id == "T2"
      assert transfer.from_stop_id == nil
      assert transfer.to_stop_id == nil
    end
  end

  defp editor_draft(organization_id, gtfs_version_id, attrs) do
    %Transfer{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
    |> Transfer.editor_changeset(attrs)
  end

  defp insert_transfer(attrs) do
    %Transfer{}
    |> Transfer.changeset(attrs)
    |> Repo.insert()
  end
end
