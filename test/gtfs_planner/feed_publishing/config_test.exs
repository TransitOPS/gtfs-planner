defmodule GtfsPlanner.FeedPublishing.ConfigTest do
  use GtfsPlanner.DataCase

  import ExUnit.CaptureLog

  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.OrganizationsFixtures

  @complete %{
    "GTFS_PUBLISH_BUCKET" => "  rivercity-transit  ",
    "GTFS_PUBLISH_ENDPOINT" => "https://storage.example.com",
    "GTFS_PUBLISH_REGION" => "us-east-1",
    "GTFS_PUBLISH_ACCESS_KEY_ID" => "publish-access-key",
    "GTFS_PUBLISH_SECRET_ACCESS_KEY" => "publish-secret-access-key",
    "GTFS_PUBLISH_PUBLIC_BASE_URL" => "https://feeds.example.com"
  }

  describe "load/1 activation" do
    test "an absent or blank activation setting disables quietly" do
      log =
        capture_log(fn ->
          assert Config.load(%{}) == :disabled
          assert Config.load(%{"GTFS_PUBLISH_BUCKET" => ""}) == :disabled
          assert Config.load(%{"GTFS_PUBLISH_BUCKET" => "   "}) == :disabled
        end)

      assert log == ""
    end

    test "mail credentials alone never activate publishing" do
      log =
        capture_log(fn ->
          assert Config.load(%{
                   "AWS_ACCESS_KEY_ID" => "ses-access-key",
                   "AWS_SECRET_ACCESS_KEY" => "ses-secret-access-key",
                   "AWS_REGION" => "us-east-1"
                 }) == :disabled
        end)

      assert log == ""
    end
  end

  describe "load/1 incomplete settings" do
    test "each missing required setting disables with one diagnostic naming the variable" do
      for variable <- Map.keys(@complete) -- ["GTFS_PUBLISH_BUCKET"] do
        env = Map.delete(@complete, variable)

        log = capture_log(fn -> assert Config.load(env) == :disabled end)

        assert log =~ variable
        assert log =~ "public feed publishing is disabled"
      end
    end

    test "a blank required setting is treated as missing" do
      env = Map.put(@complete, "GTFS_PUBLISH_REGION", "  ")

      log = capture_log(fn -> assert Config.load(env) == :disabled end)

      assert log =~ "GTFS_PUBLISH_REGION is missing or blank"
    end

    test "the diagnostic never contains a configured value" do
      env = Map.delete(@complete, "GTFS_PUBLISH_PUBLIC_BASE_URL")

      log = capture_log(fn -> assert Config.load(env) == :disabled end)

      refute log =~ "publish-access-key"
      refute log =~ "publish-secret-access-key"
      refute log =~ "storage.example.com"
      refute log =~ "rivercity-transit"
    end
  end

  describe "load/1 origins" do
    test "accepts complete settings and returns parsed origins" do
      assert {:enabled, config} = Config.load(@complete)

      assert config.bucket == "rivercity-transit"
      assert config.region == "us-east-1"
      assert config.access_key_id == "publish-access-key"
      assert config.secret_access_key == "publish-secret-access-key"
      assert config.endpoint == URI.parse("https://storage.example.com")
      assert config.public_base_url == URI.parse("https://feeds.example.com")
    end

    test "rejects origins that are not deployed HTTPS URLs" do
      rejected = [
        "http://storage.example.com",
        "https://user:secret@storage.example.com",
        "https://storage.example.com/?prefix=x",
        "https://storage.example.com/#fragment",
        "storage.example.com",
        "https://"
      ]

      for origin <- rejected,
          variable <- ["GTFS_PUBLISH_ENDPOINT", "GTFS_PUBLISH_PUBLIC_BASE_URL"] do
        env = Map.put(@complete, variable, origin)

        log = capture_log(fn -> assert Config.load(env) == :disabled end)

        assert log =~ "#{variable} must be an absolute https URL"
      end
    end
  end

  describe "current/0" do
    setup do
      original =
        Application.get_env(:gtfs_planner, :feed_publishing_config) ||
          Application.get_env(:gtfs_planner, :feed_publishing_settings)

      on_exit(fn ->
        Application.delete_env(:gtfs_planner, :feed_publishing_config)
        Application.delete_env(:gtfs_planner, :feed_publishing_settings)

        case original do
          nil -> :ok
          value -> Application.put_env(:gtfs_planner, :feed_publishing_config, value)
        end
      end)

      :ok
    end

    test "ordinary test configuration is disabled and the booted application is still usable" do
      Application.delete_env(:gtfs_planner, :feed_publishing_config)
      Application.delete_env(:gtfs_planner, :feed_publishing_settings)

      assert Config.current() == :disabled

      # Authoring and download paths keep working with publishing disabled: the
      # booted Repo still answers and an organization-scoped write still commits.
      assert %Postgrex.Result{rows: [[1]]} = Repo.query!("SELECT 1")

      attributes = OrganizationsFixtures.valid_organization_attributes()

      assert {:ok, organization} = Organizations.create_organization_unchecked(attributes)
      assert Organizations.get_organization!(organization.id)
    end

    test "reads the normalized boot value" do
      Application.delete_env(:gtfs_planner, :feed_publishing_settings)
      Application.put_env(:gtfs_planner, :feed_publishing_config, Config.load(@complete))

      assert {:enabled, config} = Config.current()
      assert config.bucket == "rivercity-transit"
    end

    test "normalizes a raw settings fixture stored by test configuration" do
      Application.delete_env(:gtfs_planner, :feed_publishing_config)
      Application.put_env(:gtfs_planner, :feed_publishing_settings, @complete)

      assert {:enabled, config} = Config.current()
      assert config.public_base_url == URI.parse("https://feeds.example.com")
    end
  end
end
