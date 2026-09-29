defmodule GtfsPlanner.Agents.PromptTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Packs.Calendars
  alias GtfsPlanner.Agents.Prompt
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.DisplayClock

  @skill_path Path.expand("../../../priv/agents/packs/calendars/SKILL.md", __DIR__)
  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  @months ~w(January February March April May June July August September October November December)

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/Los_Angeles"})
    user = user_fixture()
    organization_membership_fixture(user, organization)

    scope = %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "calendars",
      version_name: version.name
    }

    %{organization: organization, version: version, user: user, scope: scope}
  end

  describe "system/2" do
    test "returns a system message that starts with the embedded skill body", context do
      assert %{"role" => "system", "content" => content} = Prompt.system(Calendars, context.scope)

      body = skill_file_body()
      [first_line | _rest] = String.split(body, "\n")

      assert first_line != ""
      assert String.starts_with?(content, body)
      assert content =~ first_line
    end

    test "carries the agency-local date, weekday and timezone", context do
      %{"content" => content} = Prompt.system(Calendars, context.scope)

      today = DisplayClock.today(context.organization.id, context.version.id)
      assert today.timezone == "America/Los_Angeles"

      assert content =~ local_date_line(today.date, today.timezone)
      assert content =~ Date.to_iso8601(today.date)
    end

    test "carries the service version name and the pack section title", context do
      %{"content" => content} = Prompt.system(Calendars, context.scope)

      assert content =~ "Service version: #{context.version.name}."
      assert content =~ "Section: Calendar helper."
    end

    test "contains no organization, version or user identifier", context do
      %{"content" => content} = Prompt.system(Calendars, context.scope)

      refute content =~ context.organization.id
      refute content =~ context.version.id
      refute content =~ context.user.id
      refute content =~ context.user.email
    end
  end

  describe "the embedded skill" do
    test "is the SKILL.md body without front matter and carries the out-of-scope reply" do
      skill = Calendars.skill()

      refute String.starts_with?(skill, "---")
      assert skill == skill_file_body()
      assert skill =~ "That isn't available in Calendars."
    end
  end

  defp skill_file_body do
    @skill_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "---"))
    |> Enum.drop(1)
    |> Enum.drop_while(&(&1 != "---"))
    |> Enum.drop(1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp local_date_line(date, timezone) do
    weekday = Enum.at(@weekdays, Date.day_of_week(date) - 1)
    month = Enum.at(@months, date.month - 1)

    "Today is #{Date.to_iso8601(date)}, #{weekday}, #{month} #{date.day}, #{date.year} (#{timezone}), in the agency's local time."
  end
end
