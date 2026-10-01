defmodule GtfsPlanner.Alerts.AlertTest do
  @moduledoc """
  Step 2: `Alert.draft_changeset/2` casts the operator's own fields, keeps the
  server-owned ones, and refuses the values the spec bounds.
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts.Alert

  describe "draft_changeset/2 with no params" do
    test "an empty map is a valid draft" do
      changeset = Alert.draft_changeset(%Alert{}, %{})

      assert changeset.valid?
      assert changeset.changes == %{}
    end
  end

  describe "server-owned fields" do
    test "ignores organization, version, revision, complete, effect and derived dates" do
      changeset =
        Alert.draft_changeset(%Alert{}, %{
          "organization_id" => Ecto.UUID.generate(),
          "gtfs_version_id" => Ecto.UUID.generate(),
          "revision" => 99,
          "complete" => true,
          "effect" => "no_service",
          "first_date" => "2026-01-01",
          "last_date" => "2026-02-01",
          "created_by_id" => Ecto.UUID.generate(),
          "updated_by_id" => Ecto.UUID.generate()
        })

      assert changeset.valid?
      assert changeset.changes == %{}

      assert Ecto.Changeset.get_field(changeset, :revision) == 1
      assert Ecto.Changeset.get_field(changeset, :complete) == false
      assert Ecto.Changeset.get_field(changeset, :effect) == nil
      assert Ecto.Changeset.get_field(changeset, :first_date) == nil
      assert Ecto.Changeset.get_field(changeset, :last_date) == nil
      assert Ecto.Changeset.get_field(changeset, :organization_id) == nil
      assert Ecto.Changeset.get_field(changeset, :gtfs_version_id) == nil
    end

    test "ignores a stored alert's identity fields while casting operator fields" do
      alert = %Alert{
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate(),
        revision: 4,
        complete: true,
        effect: :no_service
      }

      changeset =
        Alert.draft_changeset(alert, %{
          "revision" => 99,
          "effect" => "detour",
          "cause" => "construction"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :revision) == 4
      assert Ecto.Changeset.get_field(changeset, :effect) == :no_service
      assert Ecto.Changeset.get_field(changeset, :cause) == :construction
      assert Ecto.Changeset.get_change(changeset, :organization_id) == nil
      assert Ecto.Changeset.get_change(changeset, :gtfs_version_id) == nil
    end

    test "never casts the timing answer's time_zone" do
      changeset =
        Alert.draft_changeset(%Alert{}, %{
          "timing" => %{"time_zone" => "Asia/Tokyo", "start_date" => "2026-01-01"}
        })

      assert changeset.valid?

      assert changeset.changes[:timing].changes == %{start_date: ~D[2026-01-01]}
    end
  end

  describe "operator fields" do
    test "casts urgency, situation, service_change_kind, cause and cause_detail" do
      changeset =
        Alert.draft_changeset(%Alert{}, %{
          "urgency" => "planned",
          "situation" => "stop_closed",
          "service_change_kind" => "fewer_trips",
          "cause" => "construction",
          "cause_detail" => "Bridge deck replacement."
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :urgency) == :planned
      assert Ecto.Changeset.get_field(changeset, :situation) == :stop_closed
      assert Ecto.Changeset.get_field(changeset, :service_change_kind) == :fewer_trips
      assert Ecto.Changeset.get_field(changeset, :cause) == :construction
      assert Ecto.Changeset.get_field(changeset, :cause_detail) == "Bridge deck replacement."
    end

    test "rejects an unknown situation" do
      changeset = Alert.draft_changeset(%Alert{}, %{"situation" => "fire"})

      refute changeset.valid?
      assert %{situation: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects an unknown cause and accepts special_event" do
      rejected = Alert.draft_changeset(%Alert{}, %{"cause" => "aliens"})
      refute rejected.valid?
      assert %{cause: ["is invalid"]} = errors_on(rejected)

      accepted = Alert.draft_changeset(%Alert{}, %{"cause" => "special_event"})
      assert accepted.valid?
      assert Ecto.Changeset.get_field(accepted, :cause) == :special_event
    end

    test "rejects a cause_detail over 200 characters" do
      changeset = Alert.draft_changeset(%Alert{}, %{"cause_detail" => String.duplicate("a", 201)})

      refute changeset.valid?
      assert %{cause_detail: ["should be at most 200 character(s)"]} = errors_on(changeset)
    end

    test "accepts a cause_detail of exactly 200 characters" do
      changeset = Alert.draft_changeset(%Alert{}, %{"cause_detail" => String.duplicate("a", 200)})

      assert changeset.valid?
    end
  end

  describe "scope answer" do
    test "casts a route shape with its identities" do
      route_id = Ecto.UUID.generate()
      stop_id = Ecto.UUID.generate()

      changeset =
        Alert.draft_changeset(%Alert{}, %{
          "scope" => %{
            "shape" => "route_stops",
            "route_ids" => [route_id],
            "stop_ids" => [stop_id],
            "route_stop_pairs" => [%{"route_id" => route_id, "stop_id" => stop_id}]
          }
        })

      assert changeset.valid?
      scope = Ecto.Changeset.get_field(changeset, :scope)
      assert scope.shape == :route_stops
      assert scope.route_ids == [route_id]
      assert scope.stop_ids == [stop_id]
      assert [%{route_id: ^route_id, stop_id: ^stop_id}] = scope.route_stop_pairs
    end

    test "casts trips with their service dates" do
      trip_id = Ecto.UUID.generate()

      changeset =
        Alert.draft_changeset(%Alert{}, %{
          "scope" => %{
            "shape" => "trips",
            "trips" => [%{"trip_id" => trip_id, "service_date" => "2026-01-05"}]
          }
        })

      assert changeset.valid?

      assert [%{trip_id: ^trip_id, service_date: ~D[2026-01-05]}] =
               Ecto.Changeset.get_field(changeset, :scope).trips
    end

    test "rejects more than 200 route or stop identities" do
      route_ids = List.duplicate(Ecto.UUID.generate(), 201)
      stop_ids = List.duplicate(Ecto.UUID.generate(), 201)

      routes = Alert.draft_changeset(%Alert{}, %{"scope" => %{"route_ids" => route_ids}})
      refute routes.valid?
      assert %{scope: %{route_ids: ["Choose no more than 200."]}} = errors_on(routes)

      stops = Alert.draft_changeset(%Alert{}, %{"scope" => %{"stop_ids" => stop_ids}})
      refute stops.valid?
      assert %{scope: %{stop_ids: ["Choose no more than 200."]}} = errors_on(stops)
    end

    test "accepts exactly 200 route identities" do
      route_ids = List.duplicate(Ecto.UUID.generate(), 200)

      changeset = Alert.draft_changeset(%Alert{}, %{"scope" => %{"route_ids" => route_ids}})

      assert changeset.valid?
    end

    test "rejects more than 400 route and stop pairs" do
      pairs =
        for _ <- 1..401,
            do: %{
              "route_id" => Ecto.UUID.generate(),
              "stop_id" => Ecto.UUID.generate()
            }

      changeset =
        Alert.draft_changeset(%Alert{}, %{"scope" => %{"route_stop_pairs" => pairs}})

      refute changeset.valid?
      assert %{scope: %{route_stop_pairs: ["Choose no more than 400."]}} = errors_on(changeset)
    end

    test "rejects an unknown shape and a direction outside 0 or 1" do
      shape = Alert.draft_changeset(%Alert{}, %{"scope" => %{"shape" => "everything"}})
      refute shape.valid?
      assert %{scope: %{shape: ["is invalid"]}} = errors_on(shape)

      direction =
        Alert.draft_changeset(%Alert{}, %{
          "scope" => %{"shape" => "route_direction", "direction_id" => 2}
        })

      refute direction.valid?
      assert %{scope: %{direction_id: ["must be 0 or 1"]}} = errors_on(direction)
    end
  end

  describe "timing answer" do
    test "casts a weekly repetition and its exceptions" do
      changeset =
        Alert.draft_changeset(%Alert{}, %{
          "timing" => %{
            "pattern" => "weekly",
            "first_date" => "2026-10-05",
            "weeks" => 2,
            "weekdays" => [1, 2, 3, 4, 5],
            "added_dates" => ["2026-10-12"],
            "removed_dates" => ["2026-10-09"]
          }
        })

      assert changeset.valid?
      timing = Ecto.Changeset.get_field(changeset, :timing)
      assert timing.pattern == :weekly
      assert timing.first_date == ~D[2026-10-05]
      assert timing.weeks == 2
      assert timing.weekdays == [1, 2, 3, 4, 5]
      assert timing.added_dates == [~D[2026-10-12]]
      assert timing.removed_dates == [~D[2026-10-09]]
    end

    test "rejects weeks outside 1..52" do
      for weeks <- [0, 53] do
        changeset = Alert.draft_changeset(%Alert{}, %{"timing" => %{"weeks" => weeks}})

        refute changeset.valid?
        assert %{timing: %{weeks: [message]}} = errors_on(changeset)
        assert message =~ "must be"
      end
    end

    test "rejects a weekday outside ISO 1..7" do
      for weekday <- [0, 8] do
        changeset = Alert.draft_changeset(%Alert{}, %{"timing" => %{"weekdays" => [weekday]}})

        refute changeset.valid?

        assert %{timing: %{weekdays: ["must be ISO weekdays 1 to 7 (Monday to Sunday)"]}} =
                 errors_on(changeset)
      end
    end

    test "rejects a delay estimate over 240 minutes" do
      rejected = Alert.draft_changeset(%Alert{}, %{"timing" => %{"delay_minutes" => 241}})
      refute rejected.valid?
      assert %{timing: %{delay_minutes: [message]}} = errors_on(rejected)
      assert message =~ "must be"

      accepted = Alert.draft_changeset(%Alert{}, %{"timing" => %{"delay_minutes" => 240}})
      assert accepted.valid?
    end
  end

  describe "message answer" do
    test "casts header, description and script state" do
      changeset =
        Alert.draft_changeset(%Alert{}, %{
          "message" => %{
            "header" => "Route 1 detour",
            "description" => "Buses run around the closure.",
            "script_key" => "builtin:delay",
            "customized" => true
          }
        })

      assert changeset.valid?
      message = Ecto.Changeset.get_field(changeset, :message)
      assert message.header == "Route 1 detour"
      assert message.description == "Buses run around the closure."
      assert message.script_key == "builtin:delay"
      assert message.customized == true
    end

    test "rejects a header over 120 characters and a description over 2,000" do
      header =
        Alert.draft_changeset(%Alert{}, %{"message" => %{"header" => String.duplicate("a", 121)}})

      refute header.valid?
      assert %{message: %{header: ["should be at most 120 character(s)"]}} = errors_on(header)

      description =
        Alert.draft_changeset(%Alert{}, %{
          "message" => %{"description" => String.duplicate("a", 2_001)}
        })

      refute description.valid?

      assert %{message: %{description: ["should be at most 2000 character(s)"]}} =
               errors_on(description)
    end

    test "accepts a header of exactly 120 and a description of exactly 2,000 characters" do
      changeset =
        Alert.draft_changeset(%Alert{}, %{
          "message" => %{
            "header" => String.duplicate("a", 120),
            "description" => String.duplicate("a", 2_000)
          }
        })

      assert changeset.valid?
    end

    test "rejects a url that is not http or https and accepts one that is" do
      for url <- ["javascript:alert(1)", "data:text/html,x", "ftp://example.org/x", "/relative"] do
        changeset = Alert.draft_changeset(%Alert{}, %{"message" => %{"url" => url}})

        refute changeset.valid?, "expected #{url} to be rejected"

        assert %{
                 message: %{url: ["must be a full web address starting with https:// or http://"]}
               } =
                 errors_on(changeset)
      end

      accepted =
        Alert.draft_changeset(%Alert{}, %{"message" => %{"url" => "https://example.org/x"}})

      assert accepted.valid?
      assert Ecto.Changeset.get_field(accepted, :message).url == "https://example.org/x"
    end
  end

  describe "persistence" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      %{organization: organization, version: version}
    end

    test "a saved draft keeps the server-owned defaults and reloads every answer", %{
      organization: organization,
      version: version
    } do
      route_id = Ecto.UUID.generate()
      stop_id = Ecto.UUID.generate()

      alert =
        %Alert{}
        |> Alert.draft_changeset(%{
          "urgency" => "planned",
          "situation" => "detour",
          "cause" => "construction",
          "scope" => %{
            "shape" => "route_stops",
            "route_ids" => [route_id],
            "route_stop_pairs" => [%{"route_id" => route_id, "stop_id" => stop_id}]
          },
          "timing" => %{"pattern" => "weekly", "weeks" => 2, "weekdays" => [1, 5]},
          "message" => %{"header" => "Route 1 detour"}
        })
        |> Ecto.Changeset.put_change(:organization_id, organization.id)
        |> Ecto.Changeset.put_change(:gtfs_version_id, version.id)
        |> Repo.insert!()

      loaded = Repo.get!(Alert, alert.id)

      assert loaded.revision == 1
      assert loaded.complete == false
      assert loaded.effect == nil
      assert loaded.first_date == nil
      assert loaded.last_date == nil

      assert loaded.scope.shape == :route_stops
      assert loaded.scope.route_ids == [route_id]
      assert [%{route_id: ^route_id, stop_id: ^stop_id}] = loaded.scope.route_stop_pairs
      assert loaded.timing.weekdays == [1, 5]
      assert loaded.message.header == "Route 1 detour"
    end

    test "a refused draft leaves the stored row untouched", %{
      organization: organization,
      version: version
    } do
      alert = insert_alert(organization, version, %{"situation" => "delay"})

      refused = Alert.draft_changeset(alert, %{"cause" => "aliens", "revision" => 99})

      refute refused.valid?
      assert Ecto.Changeset.get_change(refused, :revision) == nil

      assert Repo.get!(Alert, alert.id).situation == :delay
      assert Repo.get!(Alert, alert.id).revision == 1
    end
  end

  defp insert_alert(organization, version, params) do
    %Alert{}
    |> Alert.draft_changeset(params)
    |> Ecto.Changeset.put_change(:organization_id, organization.id)
    |> Ecto.Changeset.put_change(:gtfs_version_id, version.id)
    |> Repo.insert!()
  end
end
