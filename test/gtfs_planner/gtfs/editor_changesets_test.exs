defmodule GtfsPlanner.Gtfs.EditorChangesetsTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.FeedInfo

  @url_message "must be a full web address starting with https:// or http://"
  @email_message "must be an email address, such as data@example.com"
  @language_message "is not a supported language"
  @timezone_message "must be a valid timezone, such as America/New_York"
  @date_message "must be on or after the valid-from date"

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization_id: organization.id, gtfs_version_id: version.id}
  end

  describe "Agency.editor_changeset/2" do
    test "requires a name, a website and a timezone on a new agency" do
      changeset = Agency.editor_changeset(%Agency{}, %{agency_name: "", agency_url: "  "})

      assert %{
               agency_name: ["can't be blank"],
               agency_url: ["can't be blank"],
               agency_timezone: ["can't be blank"]
             } = errors_on(changeset)

      refute changeset.valid?
    end

    test "rejects an invalid website, fare website, email, timezone and language", context do
      changeset =
        Agency.editor_changeset(agency_struct(context), %{
          agency_url: "www.example.com",
          agency_fare_url: "ftp://x.example",
          agency_email: "a b@c",
          agency_timezone: "Not/a_zone",
          agency_lang: "mul"
        })

      assert %{
               agency_url: [@url_message],
               agency_fare_url: [@url_message],
               agency_email: [@email_message],
               agency_timezone: [@timezone_message],
               agency_lang: [@language_message]
             } = errors_on(changeset)
    end

    test "rejects a 256-codepoint name and accepts 255", context do
      assert %{agency_name: ["should be at most 255 character(s)"]} =
               errors_on(
                 Agency.editor_changeset(agency_struct(context), %{
                   agency_name: String.duplicate("é", 256)
                 })
               )

      assert Agency.editor_changeset(agency_struct(context), %{
               agency_name: String.duplicate("é", 255)
             }).valid?
    end

    test "treats a SQL-shaped value as data", context do
      changeset =
        Agency.editor_changeset(agency_struct(context), %{
          agency_timezone: "UTC'; DROP TABLE agencies; --",
          agency_email: "'; DROP TABLE agencies; --"
        })

      assert %{agency_timezone: [@timezone_message], agency_email: [@email_message]} =
               errors_on(changeset)

      assert Repo.aggregate(
               from(a in Agency,
                 where:
                   a.organization_id == ^context.organization_id and
                     a.gtfs_version_id == ^context.gtfs_version_id
               ),
               :count
             ) == 0
    end

    test "accepts clearing the optional language with an explicit nil", context do
      changeset =
        Agency.editor_changeset(agency_struct(context, %{agency_lang: "en-US"}), %{
          agency_lang: nil
        })

      assert changeset.valid?
      assert changeset.changes == %{agency_lang: nil}
    end

    test "keeps the phone number exactly as entered", context do
      changeset =
        Agency.editor_changeset(agency_struct(context), %{agency_phone: "(212) 555-RIDE"})

      assert changeset.valid?
      assert changeset.changes.agency_phone == "(212) 555-RIDE"
    end

    test "trims surrounding whitespace from a text change", context do
      changeset =
        Agency.editor_changeset(agency_struct(context), %{
          agency_name: "  Metro Transit Two  "
        })

      assert changeset.changes.agency_name == "Metro Transit Two"
    end

    test "accepts a phone change on a struct holding an imported website and language", context do
      changeset =
        Agency.editor_changeset(
          agency_struct(context, %{agency_url: "www.example.com", agency_lang: "en-US"}),
          %{agency_phone: "(212) 555-RIDE"}
        )

      assert changeset.valid?
      assert changeset.changes == %{agency_phone: "(212) 555-RIDE"}
    end

    test "accepts a phone change on a stored row whose timezone does not resolve", context do
      agency =
        agency_fixture(context.organization_id, context.gtfs_version_id, %{
          agency_timezone: "Not/a_zone"
        })

      changeset = Agency.editor_changeset(agency, %{agency_phone: "(212) 555-RIDE"})

      assert changeset.valid?
      assert changeset.changes == %{agency_phone: "(212) 555-RIDE"}

      assert {:ok, updated} = Repo.update(changeset)
      assert updated.agency_timezone == "Not/a_zone"
      assert Repo.get!(Agency, agency.id).agency_phone == "(212) 555-RIDE"
    end

    test "does not cast organization_id, gtfs_version_id or agency_id", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      agency =
        agency_fixture(context.organization_id, context.gtfs_version_id, %{agency_id: "metro"})

      changeset =
        Agency.editor_changeset(agency, %{
          organization_id: other_organization.id,
          gtfs_version_id: other_version.id,
          agency_id: "hijacked",
          agency_name: "Metro Transit 2"
        })

      assert changeset.changes == %{agency_name: "Metro Transit 2"}

      assert {:ok, updated} = Repo.update(changeset)
      reloaded = Repo.get!(Agency, agency.id)

      assert updated.organization_id == context.organization_id
      assert updated.gtfs_version_id == context.gtfs_version_id
      assert updated.agency_id == "metro"
      assert reloaded.organization_id == context.organization_id
      assert reloaded.gtfs_version_id == context.gtfs_version_id
      assert reloaded.agency_id == "metro"
    end

    test "the base changeset still accepts an import's unresolved zone", context do
      attrs =
        valid_agency_attrs(%{agency_timezone: "Not/a_zone", agency_url: "www.example.com"})
        |> Map.put(:organization_id, context.organization_id)
        |> Map.put(:gtfs_version_id, context.gtfs_version_id)

      assert {:ok, agency} = Gtfs.create_agency(attrs)
      assert agency.agency_timezone == "Not/a_zone"
      assert agency.agency_url == "www.example.com"
    end
  end

  describe "FeedInfo.editor_changeset/2" do
    test "requires a publisher name, a publisher website and a feed language" do
      changeset = FeedInfo.editor_changeset(%FeedInfo{}, %{})

      assert %{
               feed_publisher_name: ["can't be blank"],
               feed_publisher_url: ["can't be blank"],
               feed_lang: ["can't be blank"]
             } = errors_on(changeset)

      refute changeset.valid?
    end

    test "accepts mul as the feed language and rejects it as the default language" do
      assert FeedInfo.editor_changeset(feed_info_struct(), %{feed_lang: "mul"}).valid?

      assert %{default_lang: [@language_message]} =
               errors_on(FeedInfo.editor_changeset(feed_info_struct(), %{default_lang: "mul"}))

      assert %{feed_lang: [@language_message]} =
               errors_on(FeedInfo.editor_changeset(feed_info_struct(), %{feed_lang: "en-US"}))
    end

    test "format-checks the contact website and email" do
      assert %{feed_contact_url: [@url_message]} =
               errors_on(
                 FeedInfo.editor_changeset(feed_info_struct(), %{feed_contact_url: "https://"})
               )

      assert %{feed_contact_email: [@email_message]} =
               errors_on(
                 FeedInfo.editor_changeset(feed_info_struct(), %{feed_contact_email: "a.example"})
               )
    end

    test "rejects a publisher website that is not an absolute web address" do
      assert %{feed_publisher_url: [@url_message]} =
               errors_on(
                 FeedInfo.editor_changeset(feed_info_struct(), %{
                   feed_publisher_url: "www.example.com"
                 })
               )
    end

    test "rejects a 256-codepoint publisher name and accepts 255" do
      assert %{feed_publisher_name: ["should be at most 255 character(s)"]} =
               errors_on(
                 FeedInfo.editor_changeset(feed_info_struct(), %{
                   feed_publisher_name: String.duplicate("é", 256)
                 })
               )

      assert FeedInfo.editor_changeset(feed_info_struct(), %{
               feed_publisher_name: String.duplicate("é", 255)
             }).valid?
    end

    test "trims surrounding whitespace from a feed text change" do
      changeset =
        FeedInfo.editor_changeset(feed_info_struct(), %{
          feed_publisher_name: "  Metro Transit Two  "
        })

      assert changeset.changes.feed_publisher_name == "Metro Transit Two"
    end

    test "rejects an end date before the start date when either date changed" do
      base =
        feed_info_struct(%{feed_start_date: ~D[2026-09-01], feed_end_date: ~D[2026-08-01]})

      assert %{feed_end_date: [@date_message]} =
               errors_on(FeedInfo.editor_changeset(base, %{feed_end_date: ~D[2026-08-15]}))

      assert %{feed_end_date: [@date_message]} =
               errors_on(FeedInfo.editor_changeset(base, %{feed_start_date: ~D[2026-09-02]}))

      assert FeedInfo.editor_changeset(base, %{feed_end_date: ~D[2026-09-30]}).valid?
    end

    test "an untouched invalid date range does not block another edit" do
      base =
        feed_info_struct(%{feed_start_date: ~D[2026-09-01], feed_end_date: ~D[2026-08-01]})

      changeset = FeedInfo.editor_changeset(base, %{feed_version: "2026-09-01"})

      assert changeset.valid?
      assert changeset.changes == %{feed_version: "2026-09-01"}
    end

    test "accepts clearing the default language with an explicit nil" do
      changeset =
        FeedInfo.editor_changeset(feed_info_struct(%{default_lang: "en-US"}), %{
          default_lang: nil
        })

      assert changeset.valid?
      assert changeset.changes == %{default_lang: nil}
    end

    test "does not cast organization_id or gtfs_version_id" do
      changeset =
        FeedInfo.editor_changeset(feed_info_struct(), %{
          organization_id: Ecto.UUID.generate(),
          gtfs_version_id: Ecto.UUID.generate(),
          feed_version: "2026-09-01"
        })

      assert changeset.changes == %{feed_version: "2026-09-01"}
      refute Map.has_key?(changeset.changes, :organization_id)
      refute Map.has_key?(changeset.changes, :gtfs_version_id)
    end
  end

  defp agency_struct(context, attrs \\ %{}) do
    struct!(
      Agency,
      Enum.into(attrs, %{
        organization_id: context.organization_id,
        gtfs_version_id: context.gtfs_version_id,
        agency_id: "metro",
        agency_name: "Metro Transit",
        agency_url: "https://metro.example",
        agency_timezone: "America/New_York"
      })
    )
  end

  defp feed_info_struct(attrs \\ %{}) do
    struct!(
      FeedInfo,
      Enum.into(attrs, %{
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate(),
        feed_publisher_name: "Metro Transit",
        feed_publisher_url: "https://metro.example",
        feed_lang: "en"
      })
    )
  end
end
