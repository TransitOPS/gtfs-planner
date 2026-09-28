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

  @contact_types %{url: :string, email: :string}

  defp cast_attrs(attrs) do
    cast(%TestSchema{}, attrs, @all_fields)
  end

  defp contact_changeset(attrs, data \\ %{}) do
    cast({data, @contact_types}, attrs, [:url, :email])
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

  describe "validate_http_url/2" do
    test "accepts an http or https web address, including an uppercase scheme" do
      for url <- ["https://a.example/x", "HTTP://a.example"] do
        changeset = contact_changeset(%{url: url}) |> ChangesetHelpers.validate_http_url(:url)

        assert changeset.valid?, "expected #{inspect(url)} to be accepted"
        assert changeset.errors == []
      end
    end

    test "rejects a missing scheme, a non-web scheme and an empty host" do
      message = "must be a full web address starting with https:// or http://"

      for url <- ["www.example.com", "ftp://a.example", "https://"] do
        changeset = contact_changeset(%{url: url}) |> ChangesetHelpers.validate_http_url(:url)

        refute changeset.valid?, "expected #{inspect(url)} to be rejected"
        assert changeset.errors == [url: {message, []}]
      end
    end

    test "adds no error for a blank change or an unchanged invalid value" do
      # cast/4 drops a blank param, so change/2 builds the blank change the validator sees.
      blank =
        {%{}, @contact_types}
        |> change(%{url: ""})
        |> ChangesetHelpers.validate_http_url(:url)

      assert blank.valid?
      assert blank.changes.url == ""
      assert blank.errors == []

      dropped = contact_changeset(%{url: ""}) |> ChangesetHelpers.validate_http_url(:url)

      assert dropped.valid?
      refute Map.has_key?(dropped.changes, :url)

      unchanged =
        contact_changeset(%{email: "a@b.example"}, %{url: "www.example.com"})
        |> ChangesetHelpers.validate_http_url(:url)

      assert unchanged.valid?
      refute Map.has_key?(unchanged.changes, :url)
    end
  end

  describe "validate_email_address/2" do
    test "accepts an address with a local part and a domain" do
      changeset =
        contact_changeset(%{email: "a@b.example"})
        |> ChangesetHelpers.validate_email_address(:email)

      assert changeset.valid?
      assert changeset.errors == []
    end

    test "rejects a missing @ and a space in the local part" do
      message = "must be an email address, such as data@example.com"

      for email <- ["a.example", "a b@c"] do
        changeset =
          contact_changeset(%{email: email})
          |> ChangesetHelpers.validate_email_address(:email)

        refute changeset.valid?, "expected #{inspect(email)} to be rejected"
        assert changeset.errors == [email: {message, []}]
      end
    end

    test "adds no error for a blank change or an unchanged invalid value" do
      # cast/4 drops a blank param, so change/2 builds the blank change the validator sees.
      blank =
        {%{}, @contact_types}
        |> change(%{email: ""})
        |> ChangesetHelpers.validate_email_address(:email)

      assert blank.valid?
      assert blank.changes.email == ""
      assert blank.errors == []

      dropped = contact_changeset(%{email: ""}) |> ChangesetHelpers.validate_email_address(:email)

      assert dropped.valid?
      refute Map.has_key?(dropped.changes, :email)

      unchanged =
        contact_changeset(%{url: "https://a.example"}, %{email: "a.example"})
        |> ChangesetHelpers.validate_email_address(:email)

      assert unchanged.valid?
      refute Map.has_key?(unchanged.changes, :email)
    end
  end
end
