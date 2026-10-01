defmodule GtfsPlanner.Alerts.MessageTest do
  @moduledoc """
  Step 9: `Alerts.Message` turns an alert's answers and a script into rider text
  deterministically, digests the facts that text was generated from, flags
  customized wording a later answer made stale, and reports advisory wording
  checks (AC-12, R10).

  Every expected string is a literal from the spec's rules, the prototype
  scenarios and the research, never a value recomputed by the module under test.
  The scripts used here are the prototype's `data.js` templates with the
  placeholder vocabulary the spec fixes; no script row is stored, so nothing here
  depends on step 10's schema.

  The fill cases are pure and read no clock and no row. The cases that need an
  alert build one through `create_alert/2` and `save_draft/4`, the only writer of
  `service_alerts` (INV-1), and label its targets through the real
  `Alerts.labels_for/2`.
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Message
  alias GtfsPlanner.Alerts.MessageAnswer
  alias GtfsPlanner.Gtfs.AuditContext

  @detour_header "Route [route] detour: [first skipped] to [last skipped] not served"

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "placeholders/0 and unknown_placeholders/1" do
    test "the vocabulary is the spec's fixed list" do
      assert Message.placeholders() == [
               "route",
               "direction",
               "stop",
               "first skipped",
               "last skipped",
               "alternate stop",
               "when",
               "because",
               "minutes"
             ]
    end

    test "a template's unknown placeholders are reported in order, once each" do
      assert Message.unknown_placeholders("[route] [street]") == ["street"]
      assert Message.unknown_placeholders("[When]") == ["When"]
      assert Message.unknown_placeholders("[route] [when] [Use instead]") == ["Use instead"]
      assert Message.unknown_placeholders("[street] [route] [street]") == ["street"]
    end

    test "a padded placeholder name is unknown, because the fill would never match it" do
      assert Message.unknown_placeholders("[route ] and [ stop]") == ["route ", " stop"]
    end

    test "a template using only the vocabulary has none to report" do
      assert Message.unknown_placeholders(@detour_header) == []

      assert Message.unknown_placeholders("[when], Route [route] is not running[because].") == []
    end

    test "a template with no placeholders at all has none to report" do
      assert Message.unknown_placeholders("No service today") == []
      assert Message.unknown_placeholders(nil) == []
    end
  end

  describe "fill/2" do
    test "each placeholder takes its fact and the sentence reads as written" do
      facts = %{
        "route" => "12",
        "first skipped" => "NE 6th St",
        "last skipped" => "NE 20th St"
      }

      assert Message.fill(@detour_header, facts) ==
               "Route 12 detour: NE 6th St to NE 20th St not served"
    end

    test "a fact value containing a placeholder is inserted literally, not filled again" do
      facts = %{"route" => "[route] 12", "stop" => "[when] Square"}

      assert Message.fill("Route [route] detour at [stop]", facts) ==
               "Route [route] 12 detour at [when] Square"
    end

    test "an absent fact leaves its placeholder visible" do
      facts = %{"route" => "12"}

      assert Message.fill(@detour_header, facts) ==
               "Route 12 detour: [first skipped] to [last skipped] not served"
    end

    test "an empty fact value counts as absent, so the token stays readable" do
      assert Message.fill("Route [route] detour", %{"route" => ""}) == "Route [route] detour"

      assert Message.fill("Route [route] detour", %{"route" => "   "}) ==
               "Route [route] detour"
    end

    test "a padded token stays as written even when a fact has that name" do
      assert Message.fill("Route [route ] detour", %{"route" => "12", "route " => "12"}) ==
               "Route [route ] detour"
    end

    test "a token outside the lowercase vocabulary is never filled" do
      assert Message.fill("Route [Route] detour", %{"Route" => "12"}) == "Route [Route] detour"
      assert Message.fill("[street] closed", %{"street" => "Harney"}) == "[street] closed"
    end

    test "no placeholder, no facts and no template all produce plain text" do
      assert Message.fill("All stops served", %{"route" => "12"}) == "All stops served"
      assert Message.fill(@detour_header, %{}) == @detour_header
      assert Message.fill(nil, %{"route" => "12"}) == ""
    end

    test "markup a fact carries is stored as written, not escaped or dropped" do
      assert Message.fill("Closed at [stop]", %{"stop" => "A & B <stops>"}) ==
               "Closed at A & B <stops>"
    end
  end

  describe "digest/1" do
    test "the same facts always hash to the same value" do
      facts = %{"route" => "12", "when" => "Oct 5 to Oct 16"}

      assert Message.digest(facts) == Message.digest(facts)
    end

    test "the order facts were built in does not change the digest" do
      assert Message.digest(%{"route" => "12", "when" => "Oct 5"}) ==
               Message.digest(%{"when" => "Oct 5", "route" => "12"})
    end

    test "changing any one fact changes the digest" do
      base = %{"route" => "12", "when" => "Oct 5 to Oct 16", "stop" => "NE 6th St"}

      changed = [
        %{"route" => "30", "when" => "Oct 5 to Oct 16", "stop" => "NE 6th St"},
        %{"route" => "12", "when" => "Oct 5 to Oct 23", "stop" => "NE 6th St"},
        %{"route" => "12", "when" => "Oct 5 to Oct 16", "stop" => "NE 7th St"},
        %{"route" => "12", "when" => "Oct 5 to Oct 16"}
      ]

      digests = Enum.map([base | changed], &Message.digest/1)

      assert length(Enum.uniq(digests)) == length(digests)
    end

    test "the digest is a lowercase hex SHA-256" do
      assert Message.digest(%{"route" => "12"}) =~ ~r/\A[0-9a-f]{64}\z/
    end
  end

  describe "facts/2" do
    test "a detour's facts come from its own answers and the label map", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      first =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S6", "NE 6th St"))

      last =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S20", "NE 20th St"))

      alert = detour(context, route.id, first.id, last.id)

      assert Message.facts(alert, labels(context, alert)) == %{
               "route" => "12",
               "first skipped" => "NE 6th St",
               "last skipped" => "NE 20th St",
               "stop" => "NE 6th St",
               "when" => "Mon–Fri, 8 PM to 5 AM the next day, Oct 5 to Oct 23",
               "because" => " because of roadwork"
             }
    end

    test "the when fact is the recurrence summary, so a date change moves the fact", context do
      alert = detour(context, route_id(context, "12"), stop_id(context, "S6"), nil)

      first = Message.facts(alert, labels(context, alert))["when"]

      alert =
        save!(context.audit, alert, %{
          "timing" => %{"first_date" => "2026-10-12", "weeks" => 3}
        })

      second = Message.facts(alert, labels(context, alert))["when"]

      assert first == "Mon–Fri, 8 PM to 5 AM the next day, Oct 5 to Oct 23"
      assert second == "Mon–Fri, 8 PM to 5 AM the next day, Oct 12 to Oct 30"
      assert first != second
    end

    test "the cause's own words win over the cause's phrase", context do
      alert = detour(context, route_id(context, "12"), stop_id(context, "S6"), nil)

      alert =
        save!(context.audit, alert, %{
          "cause" => "construction",
          "cause_detail" => "night paving on Highway 101"
        })

      assert Message.facts(alert, labels(context, alert))["because"] ==
               " because of night paving on Highway 101"
    end

    test "a cause with no rider-facing phrase contributes no because fact", context do
      alert = detour(context, route_id(context, "12"), stop_id(context, "S6"), nil)

      alert = save!(context.audit, alert, %{"cause" => "unknown_cause", "cause_detail" => nil})

      refute Map.has_key?(Message.facts(alert, labels(context, alert)), "because")
    end

    test "a delay's minutes fact is the operator's estimate", context do
      alert = delay(context)

      assert Message.facts(alert, labels(context, alert))["minutes"] == "20"
    end

    test "an alert with no delay estimate has no minutes fact", context do
      alert = detour(context, route_id(context, "12"), stop_id(context, "S6"), nil)

      refute Map.has_key?(Message.facts(alert, labels(context, alert)), "minutes")
    end

    test "the operator's own words for an alternative stop become the alternate stop fact",
         context do
      stop =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S6", "NE 6th St"))

      other =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S12", "NE 12th St"))

      alert = moved_stop(context, stop.id, other.id)

      facts = Message.facts(alert, labels(context, alert))

      assert facts["stop"] == "NE 6th St"
      assert facts["alternate stop"] == "NE 12th St"
    end

    test "a direction named by the caller is offered to the template", context do
      alert = detour(context, route_id(context, "12"), stop_id(context, "S6"), nil)

      labels = labels(context, alert)
      labels = Map.put(labels, :direction, "to Lincoln City")

      assert Message.facts(alert, labels)["direction"] == "to Lincoln City"
    end

    test "a system-wide alert names no route, so a route template keeps the token visible",
         context do
      alert =
        alert_fixture(context.audit, %{
          "urgency" => "now",
          "situation" => "service_change",
          "service_change_kind" => "information"
        })

      assert Message.facts(alert, labels(context, alert))["route"] == nil

      assert Message.fill(@detour_header, Message.facts(alert, labels(context, alert))) ==
               "Route [route] detour: [first skipped] to [last skipped] not served"
    end

    test "a target that no longer resolves contributes no fact rather than a wrong name",
         context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      first =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S6", "NE 6th St"))

      last =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S20", "NE 20th St"))

      alert = detour(context, route.id, first.id, last.id)

      delete!(GtfsPlanner.Gtfs.Stop, last.id)

      facts = Message.facts(alert, labels(context, alert))

      assert facts["first skipped"] == "NE 6th St"
      refute Map.has_key?(facts, "last skipped")
    end

    test "an unanswered draft produces only the facts it can", context do
      alert = alert_fixture(context.audit, %{"urgency" => "planned"})

      assert Message.facts(alert, labels(context, alert)) == %{}
    end
  end

  describe "generate/3" do
    test "a script's two templates are filled and returned with the fact digest", context do
      alert =
        detour(context, route_id(context, "12"), stop_id(context, "S6"), stop_id(context, "S20"))

      script = %{
        key: "builtin:detour",
        name: "Detour, stops skipped",
        header_template: @detour_header,
        description_template: "[when], Route [route] buses are detoured[because]."
      }

      assert %{header: header, description: description, fact_digest: digest} =
               Message.generate(alert, script, labels(context, alert))

      assert header == "Route 12 detour: NE 6th St to NE 20th St not served"

      assert description ==
               "Mon–Fri, 8 PM to 5 AM the next day, Oct 5 to Oct 23, Route 12 buses are detoured because of roadwork."

      assert digest == Message.digest(Message.facts(alert, labels(context, alert)))
    end

    test "generating twice for the same answers returns the same text and digest", context do
      alert =
        detour(context, route_id(context, "12"), stop_id(context, "S6"), stop_id(context, "S20"))

      script = %{key: "builtin:detour", header_template: @detour_header, description_template: ""}

      assert Message.generate(alert, script, labels(context, alert)) ==
               Message.generate(alert, script, labels(context, alert))
    end

    test "a script that fills one alert's text stores the digest it was built from", context do
      alert =
        detour(context, route_id(context, "12"), stop_id(context, "S6"), stop_id(context, "S20"))

      script = %{key: "builtin:detour", header_template: @detour_header, description_template: ""}

      generated = Message.generate(alert, script, labels(context, alert))

      saved =
        save!(context.audit, alert, %{
          "message" => %{
            "header" => generated.header,
            "description" => generated.description,
            "script_key" => script.key,
            "customized" => false,
            "fact_digest" => generated.fact_digest
          }
        })

      assert saved.message.header == "Route 12 detour: NE 6th St to NE 20th St not served"
      assert saved.message.customized == false
      assert Message.review_wording?(saved, labels(context, saved)) == false
    end
  end

  describe "review_wording?/2" do
    test "customized text whose digest still matches the answers is not flagged", context do
      alert =
        detour(context, route_id(context, "12"), stop_id(context, "S6"), stop_id(context, "S20"))

      alert =
        with_message(context, alert, Message.digest(Message.facts(alert, labels(context, alert))))

      assert Message.review_wording?(alert, labels(context, alert)) == false
    end

    test "customized text whose digest differs is flagged", context do
      alert =
        detour(context, route_id(context, "12"), stop_id(context, "S6"), stop_id(context, "S20"))

      alert = with_message(context, alert, Message.digest(%{"route" => "99"}))

      assert Message.review_wording?(alert, labels(context, alert)) == true
    end

    test "text the operator customized after the answers changed is flagged", context do
      alert =
        detour(context, route_id(context, "12"), stop_id(context, "S6"), stop_id(context, "S20"))

      # The wording was written against the answers as they stood, so its digest
      # is the real facts' digest and nothing is flagged yet.
      alert =
        with_message(context, alert, Message.digest(Message.facts(alert, labels(context, alert))))

      assert Message.review_wording?(alert, labels(context, alert)) == false

      alert = save!(context.audit, alert, %{"timing" => %{"first_date" => "2026-10-12"}})

      assert Message.review_wording?(alert, labels(context, alert)) == true
    end

    test "script-generated text is never flagged, however stale its digest is", context do
      alert =
        detour(context, route_id(context, "12"), stop_id(context, "S6"), stop_id(context, "S20"))

      alert =
        with_message(context, alert, Message.digest(%{"route" => "99"}), %{
          "header" => "Route 12 detour",
          "customized" => false
        })

      assert Message.review_wording?(alert, labels(context, alert)) == false
    end

    test "a draft with no message is not flagged", context do
      alert =
        detour(context, route_id(context, "12"), stop_id(context, "S6"), stop_id(context, "S20"))

      assert Message.review_wording?(alert, labels(context, alert)) == false
    end

    test "customized text with no digest stored is flagged", context do
      alert =
        detour(context, route_id(context, "12"), stop_id(context, "S6"), stop_id(context, "S20"))

      alert = with_message(context, alert, nil)

      assert Message.review_wording?(alert, labels(context, alert)) == true
    end
  end

  describe "checks/2" do
    test "a 61-character header is flagged and a 60-character one is not" do
      sixty = String.duplicate("a", 60)
      sixty_one = String.duplicate("a", 61)

      assert check(%{header: sixty}, %{}, :short).ok?
      refute check(%{header: sixty_one}, %{}, :short).ok?
      assert check(%{header: sixty_one}, %{}, :short).text =~ "61 characters"
    end

    test "a header naming no route or stop label is flagged" do
      facts = %{"route" => "12", "stop" => "NE 6th St"}

      refute check(%{header: "Service change downtown"}, facts, :target).ok?
      assert check(%{header: "Route 12 detour: NE 6th St not served"}, facts, :target).ok?
      assert check(%{header: "NE 6th St stop closed"}, facts, :target).ok?
    end

    test "naming one of several affected routes is enough" do
      facts = %{"route" => "12 and 30"}

      assert check(%{header: "Route 30 detour: Marview St not served"}, facts, :target).ok?
      refute check(%{header: "Service change downtown"}, facts, :target).ok?
    end

    test "an alert with no route or stop target has no header name to check" do
      assert check(%{header: "Free rides on Election Day"}, %{}, :target).ok?
    end

    test "a description that does not carry the when fact is flagged" do
      facts = %{"when" => "Mon–Fri, 8 PM to 5 AM the next day, Oct 5 to Oct 23"}

      refute check(%{description: "Route 12 buses are detoured."}, facts, :when).ok?

      assert check(
               %{
                 description:
                   "Mon–Fri, 8 PM to 5 AM the next day, Oct 5 to Oct 23, buses are detoured."
               },
               facts,
               :when
             ).ok?
    end

    test "an alert with no when answer has nothing for the when check to say" do
      assert check(%{description: "Route 12 buses are detoured."}, %{}, :when).ok?
    end

    test "markup characters in either field are flagged" do
      refute check(%{header: "Route <b>12</b> detour"}, %{}, :plain_text).ok?
      refute check(%{header: "Route 12 detour", description: "Use A > B"}, %{}, :plain_text).ok?
      assert check(%{header: "Route 12 detour", description: "Use A and B"}, %{}, :plain_text).ok?
    end

    test "an empty message is reported without raising" do
      assert [%{key: :short}, %{key: :target}, %{key: :when}, %{key: :plain_text}] =
               Message.checks(%MessageAnswer{}, %{})
    end

    test "checks are advisory: nothing about them changes the stored message", context do
      alert =
        detour(context, route_id(context, "12"), stop_id(context, "S6"), stop_id(context, "S20"))

      header = String.duplicate("a", 61)

      alert =
        with_message(context, alert, nil, %{"header" => header, "description" => "No times here."})

      results = Message.checks(alert.message, Message.facts(alert, labels(context, alert)))

      refute Enum.all?(results, & &1.ok?)

      reread = Repo.get!(Alert, alert.id)

      assert reread.message.header == header
      assert reread.revision == alert.revision
    end
  end

  # -- Fixtures ------------------------------------------------------------

  # The labels the real `labels_for/2` produces, plus the direction name the
  # direction step knows and this pure function cannot read.
  defp labels(context, alert) do
    Alerts.labels_for(context.audit, alert)
  end

  defp route_attrs(route_id, short_name, overrides \\ []) do
    Map.merge(
      %{route_id: route_id, route_short_name: short_name, route_type: 3},
      Map.new(overrides)
    )
  end

  defp stop_attrs(stop_id, stop_name, overrides \\ []) do
    Map.merge(
      %{
        stop_id: stop_id,
        stop_name: stop_name,
        location_type: 0,
        stop_lat: Decimal.new("40.0"),
        stop_lon: Decimal.new("-74.0")
      },
      Map.new(overrides)
    )
  end

  defp route_id(context, route_id) do
    route_fixture(context.organization.id, context.version.id, route_attrs(route_id, route_id)).id
  end

  # The stops the detour cases read, named the way riders know them.
  @stop_names %{"S6" => "NE 6th St", "S20" => "NE 20th St"}

  defp stop_id(context, stop_id) do
    name = Map.get(@stop_names, stop_id, stop_id)

    stop_fixture(context.organization.id, context.version.id, stop_attrs(stop_id, name)).id
  end

  # A planned weekly detour with a confirmed end, the shape the detour script
  # reads: two routes' worth of dates, roadwork, and the stops it skips.
  defp detour(context, route_id, from_stop_id, to_stop_id) do
    alert =
      alert_fixture(context.audit, %{
        "urgency" => "planned",
        "situation" => "detour",
        "cause" => "construction",
        "scope" => %{
          "shape" => "route_stops",
          "route_ids" => [route_id],
          "stop_ids" => Enum.reject([from_stop_id, to_stop_id], &is_nil/1),
          "stretch_from_stop_id" => from_stop_id,
          "stretch_to_stop_id" => to_stop_id
        }
      })

    save!(context.audit, alert, %{
      "timing" => %{
        "pattern" => "weekly",
        "first_date" => "2026-10-05",
        "weeks" => 3,
        "weekdays" => [1, 2, 3, 4, 5],
        "start_time" => "20:00:00",
        "end_time" => "05:00:00",
        "end_kind" => "confirmed",
        "end_date" => "2026-10-23"
      }
    })
  end

  defp moved_stop(context, stop_id, alternative_stop_id) do
    alert =
      alert_fixture(context.audit, %{
        "urgency" => "now",
        "situation" => "stop_moved",
        "cause" => "construction",
        "scope" => %{
          "shape" => "stop_all_routes",
          "stop_ids" => [stop_id],
          "alternative_stop_id" => alternative_stop_id
        }
      })

    save!(context.audit, alert, %{
      "timing" => %{
        "start_date" => "2026-10-05",
        "start_time" => "08:00:00",
        "end_kind" => "confirmed",
        "end_date" => "2026-10-06",
        "end_time" => "18:00:00"
      }
    })
  end

  defp delay(context) do
    alert =
      alert_fixture(context.audit, %{
        "urgency" => "now",
        "situation" => "delay",
        "cause" => "maintenance",
        "scope" => %{"shape" => "routes", "route_ids" => [route_id(context, "12")]}
      })

    save!(context.audit, alert, %{
      "timing" => %{
        "start_date" => "2026-10-05",
        "start_time" => "08:00:00",
        "end_kind" => "estimated",
        "check_in_at" => "2026-10-05 12:00:00",
        "delay_minutes" => 20
      }
    })
  end

  # Stores a message answer the editor would have written, marking it customized
  # unless a case says otherwise.
  defp with_message(context, alert, fact_digest, overrides \\ %{}) do
    message =
      %{"customized" => true}
      |> Map.merge(overrides)
      |> Map.put("fact_digest", fact_digest)

    save!(context.audit, alert, %{"message" => message})
  end

  defp check(message_fields, facts, key) do
    Enum.find(Message.checks(struct(MessageAnswer, message_fields), facts), &(&1.key == key))
  end

  defp save!(audit, alert, attrs) do
    assert {:ok, saved} = Alerts.save_draft(audit, alert.id, alert.revision, attrs)
    saved
  end

  defp delete!(schema, id) do
    schema |> Repo.get!(id) |> Repo.delete!()
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end
end
