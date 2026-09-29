defmodule GtfsPlanner.Gtfs.PathwayTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [get_field: 2]

  alias GtfsPlanner.Gtfs.Pathway

  @exit_gate 7

  defp pathway(attrs) do
    struct!(
      %Pathway{
        pathway_id: "pw-1",
        pathway_mode: 1,
        is_bidirectional: true,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate(),
        from_stop_id: "from",
        to_stop_id: "to"
      },
      attrs
    )
  end

  describe "changeset/2 for exit gates" do
    test "stores a new two-way exit gate as one-way" do
      attrs = %{
        pathway_id: "pw-1",
        pathway_mode: @exit_gate,
        is_bidirectional: true,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate(),
        from_stop_id: "from",
        to_stop_id: "to"
      }

      changeset = Pathway.changeset(%Pathway{}, attrs)

      assert changeset.valid?
      assert get_field(changeset, :is_bidirectional) == false
    end

    test "stores an existing walkway switched to exit gate as one-way" do
      changeset =
        Pathway.changeset(pathway(%{pathway_mode: 1, is_bidirectional: true}), %{
          pathway_mode: @exit_gate
        })

      assert changeset.valid?
      assert get_field(changeset, :is_bidirectional) == false
    end

    test "keeps an existing exit gate one-way when only is_bidirectional is set" do
      changeset =
        Pathway.changeset(pathway(%{pathway_mode: @exit_gate, is_bidirectional: false}), %{
          is_bidirectional: true
        })

      assert changeset.valid?
      assert get_field(changeset, :is_bidirectional) == false
    end

    test "leaves a two-way walkway two-way" do
      changeset =
        Pathway.changeset(pathway(%{pathway_mode: 1}), %{pathway_mode: 1, is_bidirectional: true})

      assert changeset.valid?
      assert get_field(changeset, :is_bidirectional) == true
    end
  end
end
