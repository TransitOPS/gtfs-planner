defmodule GtfsPlanner.Gtfs.FareZoneTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias GtfsPlanner.Gtfs.FareZone

  @palette_keys ["ocean", "teal", "plum", "ochre", "green"]

  describe "palette/0 and color_hex/1" do
    test "exposes the five palette keys with their prototype hex values" do
      assert Enum.map(FareZone.palette(), fn {key, _label, _hex} -> key end) == @palette_keys

      assert FareZone.color_hex("ocean") == "#1f5fbf"
      assert FareZone.color_hex("teal") == "#0d737d"
      assert FareZone.color_hex("plum") == "#4b1f78"
      assert FareZone.color_hex("ochre") == "#8a5a0e"
      assert FareZone.color_hex("green") == "#267548"
    end

    test "every palette entry carries a label and the same hex color_hex/1 returns" do
      for {key, label, hex} <- FareZone.palette() do
        assert key in @palette_keys
        assert is_binary(label) and label != ""
        assert is_binary(hex)
        assert FareZone.color_hex(key) == hex
      end
    end
  end

  describe "default_color/1" do
    test "returns the same palette key for the same ID on repeated calls" do
      for id <- ["A", " A", "ExpressBus-Downtown", "Zone 1", String.duplicate("x", 64)] do
        assert FareZone.default_color(id) == FareZone.default_color(id)
      end
    end

    test "always returns a palette key" do
      for n <- 1..50 do
        assert FareZone.default_color("ZONE_#{n}") in @palette_keys
      end

      assert FareZone.default_color("") in @palette_keys
    end

    test "spreads different IDs across the palette" do
      keys = for n <- 1..20, do: FareZone.default_color("ZONE_#{n}")

      assert length(Enum.uniq(keys)) > 1
    end
  end

  describe "changeset/3 :new" do
    test "trims the entered ID and name and is valid" do
      changeset =
        FareZone.changeset(%FareZone{}, attrs(%{"zone_id" => "  ExpressBus-Downtown "}), :new)

      assert changeset.valid?
      assert get_change(changeset, :zone_id) == "ExpressBus-Downtown"
      assert get_change(changeset, :name) == "Central"
    end

    test "accepts a 64-character ID of safe characters" do
      zone_id = "Ab_9-" <> String.duplicate("z", 59)

      assert String.length(zone_id) == 64
      assert FareZone.changeset(%FareZone{}, attrs(%{"zone_id" => zone_id}), :new).valid?
    end

    test "rejects a 65-character ID" do
      zone_id = String.duplicate("a", 65)

      changeset = FareZone.changeset(%FareZone{}, attrs(%{"zone_id" => zone_id}), :new)

      refute changeset.valid?
      assert Keyword.get(changeset.errors, :zone_id) == format_message()
    end

    test "rejects an ID with a character outside letters, numbers, hyphens and underscores" do
      changeset = FareZone.changeset(%FareZone{}, attrs(%{"zone_id" => "zone.1"}), :new)

      refute changeset.valid?
      assert Keyword.get(changeset.errors, :zone_id) == format_message()
    end

    test "rejects a blank ID with the required message" do
      changeset = FareZone.changeset(%FareZone{}, attrs(%{"zone_id" => "   "}), :new)

      refute changeset.valid?

      assert Keyword.get(changeset.errors, :zone_id) ==
               {"can't be blank", [validation: :required]}
    end

    test "requires a name and trims it before checking length" do
      blank = FareZone.changeset(%FareZone{}, attrs(%{"name" => "   "}), :new)

      refute blank.valid?
      assert Keyword.get(blank.errors, :name) == {"can't be blank", [validation: :required]}

      longest =
        FareZone.changeset(%FareZone{}, attrs(%{"name" => String.duplicate("n", 60)}), :new)

      assert longest.valid?

      too_long =
        FareZone.changeset(
          %FareZone{},
          attrs(%{"name" => "  " <> String.duplicate("n", 61) <> "  "}),
          :new
        )

      refute too_long.valid?
      assert Keyword.has_key?(too_long.errors, :name)
    end

    test "requires a palette color" do
      for key <- @palette_keys do
        assert FareZone.changeset(%FareZone{}, attrs(%{"color" => key}), :new).valid?
      end

      changeset = FareZone.changeset(%FareZone{}, attrs(%{"color" => "magenta"}), :new)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :color)
    end

    test "declares the unique index with the in-use message" do
      changeset = FareZone.changeset(%FareZone{}, attrs(%{}), :new)

      assert [constraint] = changeset.constraints
      assert constraint.type == :unique
      assert constraint.constraint == "fare_zones_organization_id_gtfs_version_id_zone_id_index"
      assert constraint.error_message == "That zone ID is already in use. Choose another."
    end
  end

  describe "changeset/3 :keep" do
    test "keeps the stored ID bytes even when attrs carry the trimmed ID" do
      changeset =
        FareZone.changeset(
          stored_zone(" A"),
          %{"zone_id" => "A", "name" => " Central ", "color" => "ocean"},
          :keep
        )

      assert changeset.valid?
      assert get_field(changeset, :zone_id) == " A"
      refute Map.has_key?(changeset.changes, :zone_id)
      assert get_change(changeset, :name) == "Central"
    end

    test "keeps an imported ID that :new would reject" do
      changeset =
        FareZone.changeset(
          stored_zone("Zone 1"),
          %{"name" => "Downtown", "color" => "teal"},
          :keep
        )

      assert changeset.valid?
      assert get_field(changeset, :zone_id) == "Zone 1"
      refute Map.has_key?(changeset.changes, :zone_id)
    end

    test "keeps the ID bytes when only the color changes" do
      changeset = FareZone.changeset(stored_zone(" A"), %{"color" => "plum"}, :keep)

      assert changeset.valid?
      assert get_change(changeset, :color) == "plum"
      assert get_field(changeset, :zone_id) == " A"
    end

    test "still requires a name, a color and a stored ID" do
      refute FareZone.changeset(stored_zone("A"), %{"name" => "   "}, :keep).valid?
      refute FareZone.changeset(stored_zone("A"), %{"color" => "magenta"}, :keep).valid?
      refute FareZone.changeset(%FareZone{}, %{"name" => "Central"}, :keep).valid?
    end
  end

  defp attrs(overrides) do
    Map.merge(%{"zone_id" => "ZONE_1", "name" => "Central", "color" => "ocean"}, overrides)
  end

  defp stored_zone(zone_id) do
    %FareZone{zone_id: zone_id, name: "Old name", color: "teal"}
  end

  defp format_message do
    {"Use 1–64 letters, numbers, hyphens or underscores.", [validation: :format]}
  end
end
