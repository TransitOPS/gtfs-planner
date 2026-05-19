defmodule GtfsPlanner.ChangesetHelpersTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias GtfsPlanner.ChangesetHelpers

  defmodule TestSchema do
    use Ecto.Schema

    embedded_schema do
      field :name, :string
      field :description, :string
      field :secret, :string
      field :count, :integer
      field :active, :boolean
      field :amount, :decimal
      field :metadata, :map
      field :timestamp, :utc_datetime_usec
      field :tags, {:array, :string}
      field :status, Ecto.Enum, values: [:draft, :published]
    end
  end

  @all_fields [
    :name,
    :description,
    :secret,
    :count,
    :active,
    :amount,
    :metadata,
    :timestamp,
    :tags,
    :status
  ]

  defp cast_attrs(attrs) do
    cast(%TestSchema{}, attrs, @all_fields)
  end

  describe "trim_string_fields/2" do
    test "trims a changed :string field with surrounding whitespace" do
      changeset =
        %{name: "  hello  "}
        |> cast_attrs()
        |> ChangesetHelpers.trim_string_fields()

      assert get_change(changeset, :name) == "hello"
    end

    test "leaves an unchanged :string field absent from changeset.changes" do
      changeset =
        %{name: "kept"}
        |> cast_attrs()
        |> ChangesetHelpers.trim_string_fields()

      refute Map.has_key?(changeset.changes, :description)
    end

    test "preserves nil changes" do
      changeset =
        %TestSchema{name: "existing"}
        |> cast(%{name: nil}, @all_fields)
        |> ChangesetHelpers.trim_string_fields()

      assert Map.fetch!(changeset.changes, :name) == nil
    end

    test "does not modify non-string type changes" do
      timestamp = ~U[2024-01-02 03:04:05.000000Z]

      attrs = %{
        count: 7,
        active: true,
        amount: Decimal.new("1.50"),
        metadata: %{"key" => "  value  "},
        timestamp: timestamp,
        tags: ["  a  ", "  b  "],
        status: :draft
      }

      changeset =
        attrs
        |> cast_attrs()
        |> ChangesetHelpers.trim_string_fields()

      assert get_change(changeset, :count) == 7
      assert get_change(changeset, :active) == true
      assert Decimal.equal?(get_change(changeset, :amount), Decimal.new("1.50"))
      assert get_change(changeset, :metadata) == %{"key" => "  value  "}
      assert get_change(changeset, :timestamp) == timestamp
      assert get_change(changeset, :tags) == ["  a  ", "  b  "]
      assert get_change(changeset, :status) == :draft
    end

    test "honors except: [:secret]" do
      changeset =
        %{name: "  trim me  ", secret: "  keep me  "}
        |> cast_attrs()
        |> ChangesetHelpers.trim_string_fields(except: [:secret])

      assert get_change(changeset, :name) == "trim me"
      assert get_change(changeset, :secret) == "  keep me  "
    end

    test "is idempotent" do
      changeset = cast_attrs(%{name: "  hello  ", description: "  world  "})

      once = ChangesetHelpers.trim_string_fields(changeset)
      twice = ChangesetHelpers.trim_string_fields(once)

      assert once.changes == twice.changes
    end
  end
end
