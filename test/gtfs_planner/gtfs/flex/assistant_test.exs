defmodule GtfsPlanner.Gtfs.Flex.AssistantTest do
  @moduledoc """
  Merge evidence (EV-2) for `GtfsPlanner.Gtfs.Flex.Assistant.prepare/2` and
  `preview/2`: the pure validation of a complete supported hours/booking
  candidate and the native comparison it produces.

  The expectations are hand-derived from the acceptance cases and from the
  native Flex wording, not from a second invocation of the module under test:

    * The representative fixture's "Newport Dial-a-Ride" is an area service with
      two areas (`a1` Newport, `a2` Toledo), weekday and Saturday hours and two
      booking rules: a service-wide business-day rule on the `office` calendar
      and a Saturday-scoped rule. A proposal of `08:00`–`17:00` for `a1` on the
      weekday calendar and one business day by 15:00 therefore reads as "Newport
      only: Weekdays 8:00 am–5:00 pm" and "Book Monday trips by 3:00 pm the
      Friday before", and exports as booking type 2 with
      `prior_notice_last_day` 1, `prior_notice_last_time` `15:00:00` and
      `prior_notice_service_id` `office`.
    * An end at or before the start is the next day (R6), so `22:00`–`02:00`
      spans four hours across midnight and `08:00`–`08:00` spans twenty-four.
      Neither is a zero or negative window, so neither raises the readiness
      finding a window over sixteen hours raises.
    * A business-day rule depends on an actual OFFICE calendar identity, so a
      holiday exception on that calendar is part of the workspace the
      preparation is built from, and the rule is never flattened to calendar
      days.
    * A policy statement this slice cannot represent — "same-day if the
      dispatcher permits" — blocks a complete supported preparation, and an
      explicit hours-only preparation keeps every booking rule and reports the
      statement as an exclusion instead of inventing a guaranteed same-day rule.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Assistant
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Repo

  describe "a supported candidate yields native wording and export fields (AC-4, AC-5)" do
    setup :flex_context

    test "prepares complete hours and booking arrays against the saved service", context do
      scope = scope_with_source(context.scope, context.area.id)

      assert {:ok, prepared} = Assistant.prepare(scope, supported_input())

      # The complete arrays were replaced, and the answer is bound to the
      # accepted source, the conversation context and the saved dependencies.
      assert prepared.prepare_scope == :all_supported
      assert prepared.replaced == [:hours, :booking_rules]
      assert prepared.service_id == context.area.id
      assert prepared.saved_lock_version == context.area.lock_version
      assert prepared.unsupported == []
      assert prepared.saved_fingerprint == fingerprint_of(context)
      assert prepared.source_digest == source_digest_of(context)
      assert prepared.context_digest == Scope.context_digest(scope)

      # The generated wording is the native wording for the candidate, not a
      # summary of it: the area prefixes its own name and the business-day rule
      # books Monday trips by the new time the Friday before.
      assert "Newport only: Weekdays 8:00 am–5:00 pm" in prepared.rider_text.candidate.hours_lines

      assert "Book Monday trips by 3:00 pm the Friday before" in prepared.rider_text.candidate.deadline_lines

      assert prepared.rider_text.candidate.message =~
               "Book Monday trips by 3:00 pm the Friday before"

      # The rider-facing difference is the native "what changed" list.
      # The hours difference is grouped by calendar, as the native rider text
      # words it, and the two areas that share the weekday calendar read as one
      # line rather than one line per area.
      assert "Weekdays: 7:00 am–6:00 pm and 9:00 am–3:00 pm → 8:00 am–5:00 pm and 9:00 am–3:00 pm" in prepared.rider_text.changes

      assert "Booking: book by 3:00 pm 1 business day before" in prepared.rider_text.changes

      # The export fields are the native `booking_rules.txt` columns the rules
      # produce, with the office calendar still named for the business day.
      [main_rule, saturday_rule] = prepared.export.candidate.booking_rule_fields

      assert main_rule.booking_rule_id == "flex-newport-dial-a-ride-book"
      assert main_rule.booking_type == 2
      assert main_rule.prior_notice_last_day == 1
      assert main_rule.prior_notice_last_time == "15:00:00"
      assert main_rule.prior_notice_service_id == "office"
      assert main_rule.phone_number == "(541) 555-0142"
      assert main_rule.booking_url == "https://example.org/book"

      assert saturday_rule.booking_rule_id == "flex-newport-dial-a-ride-book-saturday"
      assert saturday_rule.prior_notice_last_day == 2
      assert saturday_rule.prior_notice_last_time == "12:00:00"
      assert saturday_rule.prior_notice_service_id == nil

      # The export plan is the service page's own plan over the candidate.
      assert prepared.export.candidate.headline =~ "booking rule"

      assert prepared.export.candidate.rows |> Enum.map(& &1.file) |> Enum.uniq() == [
               "booking_rules.txt"
             ]

      # One planned row per rule the candidate exports.
      assert length(prepared.export.candidate.rows) == 2

      assert %{file: "booking_rules.txt", id: "flex-newport-dial-a-ride-book", summary: summary} =
               Enum.find(
                 prepared.export.candidate.rows,
                 &(&1.id == "flex-newport-dial-a-ride-book")
               )

      assert summary =~ "booking_type 2"
      assert summary =~ "prior_notice_last_time 15:00:00"
      assert summary =~ "prior_notice_service_id office"
    end

    test "reports the exact saved rows, candidate rows and changed fields", context do
      assert {:ok, prepared} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(supported_input())

      # Ordinal 0 is the only hours row the proposal changed; the Saturday
      # window it also touched is reported, and the two rows the candidate kept
      # verbatim are named as unchanged rather than dropped.
      assert Enum.map(prepared.hours.changed, & &1.ordinal) == [0]
      assert hd(prepared.hours.changed).fields == ["end", "start"]

      assert hd(prepared.hours.changed).before == %{
               "area_key" => "a1",
               "service_id" => "weekday",
               "start" => "07:00",
               "end" => "18:00"
             }

      assert hd(prepared.hours.changed).after == %{
               "area_key" => "a1",
               "service_id" => "weekday",
               "start" => "08:00",
               "end" => "17:00"
             }

      assert prepared.hours.unchanged == [1, 2, 3]
      assert prepared.hours.added == []
      assert prepared.hours.removed == []

      assert length(prepared.hours.saved) == 4
      assert length(prepared.hours.candidate) == 4

      # The booking arrays were enumerated completely, so only the main rule
      # differs and the Saturday rule is reported as unchanged.
      assert Enum.map(prepared.booking_rules.changed, & &1.ordinal) == [0]
      assert hd(prepared.booking_rules.changed).fields == ["by"]
      assert prepared.booking_rules.unchanged == [1]
      assert prepared.booking_rules.added == []
      assert prepared.booking_rules.removed == []

      # Nothing outside the two arrays moved: the phone, the booking link, the
      # eligibility, the drop-off policy and the areas are all named as
      # untouched, and the candidate struct still holds the saved geometry.
      assert prepared.changed_fields == []
      assert prepared.areas_changed? == false
      assert :phone in prepared.unchanged_fields
      assert :booking_url in prepared.unchanged_fields
      assert :eligibility in prepared.unchanged_fields
      assert Enum.map(prepared.candidate.areas, & &1.key) == ["a1", "a2"]

      # The candidate is a struct with the new rows and the saved lock version;
      # nothing about it was persisted.
      assert Enum.map(prepared.candidate.hours, & &1.start) == [
               "08:00",
               "09:00",
               "18:00",
               "09:00"
             ]

      assert prepared.candidate.lock_version == context.area.lock_version
    end

    test "the patch is exactly what the native page would submit", context do
      assert {:ok, prepared} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(supported_input())

      assert prepared.patch == %{
               "hours" => [
                 %{
                   "area_key" => "a1",
                   "service_id" => "weekday",
                   "start" => "08:00",
                   "end" => "17:00"
                 },
                 %{
                   "area_key" => "a2",
                   "service_id" => "weekday",
                   "start" => "09:00",
                   "end" => "15:00"
                 },
                 %{
                   "area_key" => "a1",
                   "service_id" => "saturday",
                   "start" => "18:00",
                   "end" => "01:00"
                 },
                 %{
                   "area_key" => "a2",
                   "service_id" => "saturday",
                   "start" => "09:00",
                   "end" => "15:00"
                 }
               ],
               "booking_rules" => [
                 %{
                   "service_id" => nil,
                   "when" => "earlier_day",
                   "minutes" => nil,
                   "days" => 1,
                   "by" => "15:00",
                   "business_days" => true,
                   "office_service_id" => "office",
                   "max_days" => nil
                 },
                 %{
                   "service_id" => "saturday",
                   "when" => "earlier_day",
                   "minutes" => nil,
                   "days" => 2,
                   "by" => "12:00",
                   "business_days" => false,
                   "office_service_id" => nil,
                   "max_days" => nil
                 }
               ]
             }
    end
  end

  describe "next-day windows and business days keep native semantics (AC-5)" do
    setup :flex_context

    test "an end at or before the start spans the next day, never zero", context do
      input = %{
        "scope" => "all_supported",
        "hours" => [
          %{"area_key" => "a1", "service_id" => "weekday", "start" => "22:00", "end" => "02:00"},
          %{"area_key" => "a2", "service_id" => "weekday", "start" => "09:00", "end" => "15:00"}
        ]
      }

      assert {:ok, prepared} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(input)

      # The overnight row reads as the next day, so it is a four-hour window
      # rather than a negative or zero one, and it introduces no finding.
      assert "Newport only: Weekdays 10:00 pm–2:00 am (next day)" in prepared.rider_text.candidate.hours_lines

      assert "Toledo only: Weekdays 9:00 am–3:00 pm" in prepared.rider_text.candidate.hours_lines
      assert prepared.checks.introduced == []

      # The rows the complete array left out are reported as removals for the
      # native review rather than silently disappearing.
      assert Enum.map(prepared.hours.removed, & &1.ordinal) == [2, 3]
      assert prepared.hours.unchanged == [1]
      assert prepared.hours.added == []
    end

    test "equal clocks span twenty-four hours, so native readiness owns the refusal", context do
      input = %{
        "scope" => "all_supported",
        "hours" => [
          %{"area_key" => "a1", "service_id" => "weekday", "start" => "08:00", "end" => "08:00"},
          %{"area_key" => "a2", "service_id" => "weekday", "start" => "09:00", "end" => "15:00"}
        ]
      }

      # The equal clocks are a full twenty-four hours, which the native window
      # reading and the native readiness check own (R6). A window of zero or a
      # negative one would raise nothing, so the finding is the proof that the
      # row was never flattened.
      assert {:error, {:unsupported, {:contradictory_policy, [text]}}} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(input)

      assert text == "These hours run 24 hours, into the next day. Check the end time."
    end

    test "a business-day rule resolves the office calendar, not a weekday guess", context do
      # The office calendar takes a holiday off, so an office day is not simply
      # a weekday and the workspace the preparation is built from carries the
      # exception.
      add_office_exception(context)

      assert {:ok, workspace, _evidence} = Assistant.workspace(context.scope, context.area.id)
      assert workspace.calendar_rows["office"].exceptions != []

      input = %{
        "scope" => "all_supported",
        "booking_rules" => [
          %{
            "service_id" => nil,
            "when" => "earlier_day",
            "days" => 1,
            "by" => "16:00",
            "business_days" => true,
            "office_service_id" => "office"
          },
          %{
            "service_id" => "saturday",
            "when" => "earlier_day",
            "days" => 2,
            "by" => "12:00"
          }
        ]
      }

      assert {:ok, prepared} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(input)

      # The rule is still a business-day rule naming the office calendar: it is
      # never flattened to calendar days, and the rider text keeps the business
      # day wording.
      assert hd(prepared.candidate.booking_rules).business_days == true
      assert hd(prepared.candidate.booking_rules).office_service_id == "office"

      assert "Book Monday trips by 4:00 pm the Friday before" in prepared.rider_text.candidate.deadline_lines

      assert hd(prepared.export.candidate.booking_rule_fields).prior_notice_service_id == "office"
      assert hd(prepared.export.candidate.booking_rule_fields).prior_notice_last_day == 1
    end
  end

  describe "unresolved and unsupported policy refuses (AC-6)" do
    setup :flex_context

    test "a missing office calendar leaves the preparation unresolved", context do
      delete_calendar(context, "office")

      assert {:error, {:incomplete, {:missing_calendar, "office"}}} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(supported_input())
    end

    test "an unknown area or calendar is refused, not cast", context do
      assert {:error, {:invalid_input, {:unknown_area, "a9"}}} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(%{
                 "scope" => "all_supported",
                 "hours" => [
                   %{
                     "area_key" => "a9",
                     "service_id" => "weekday",
                     "start" => "08:00",
                     "end" => "17:00"
                   }
                 ]
               })

      assert {:error, {:invalid_input, {:unknown_calendar, "service_id", "weekdays"}}} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(%{
                 "scope" => "all_supported",
                 "hours" => [
                   %{
                     "area_key" => "a1",
                     "service_id" => "weekdays",
                     "start" => "08:00",
                     "end" => "17:00"
                   }
                 ]
               })

      # An office calendar that is not this version's is refused the same way,
      # so a business-day rule cannot be pointed at another version's calendar.
      assert {:error,
              {:invalid_input, {:unknown_calendar, "office_service_id", "office-elsewhere"}}} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(%{
                 "scope" => "all_supported",
                 "booking_rules" => [
                   %{
                     "service_id" => nil,
                     "when" => "earlier_day",
                     "days" => 1,
                     "by" => "16:00",
                     "business_days" => true,
                     "office_service_id" => "office-elsewhere"
                   }
                 ]
               })
    end

    test "a business-day rule with no office calendar is refused, not exported as calendar days",
         context do
      scope = scope_with_source(context.scope, context.area.id)

      rule = %{
        "service_id" => nil,
        "when" => "earlier_day",
        "days" => 1,
        "by" => "15:00",
        "business_days" => true
      }

      # Omitted, null and blank all leave the office calendar unresolved. The
      # export column `prior_notice_service_id` would be empty, so a consumer
      # would count calendar days under rider wording that says business days.
      for row <- [
            rule,
            Map.put(rule, "office_service_id", nil),
            Map.put(rule, "office_service_id", "")
          ] do
        assert {:error, {:invalid_input, {:booking_rules, 0, :office_calendar_required}}} =
                 Assistant.prepare(scope, %{"scope" => "all_supported", "booking_rules" => [row]})
      end

      # The same days counted as calendar days need no office calendar.
      assert {:ok, prepared} =
               Assistant.prepare(scope, %{
                 "scope" => "all_supported",
                 "booking_rules" => [Map.put(rule, "business_days", false)]
               })

      assert hd(prepared.candidate.booking_rules).business_days == false
    end

    test "discretionary same-day prose blocks a complete preparation", context do
      statement = "Same-day booking if the dispatcher permits it."
      scope = scope_with_source(context.scope, context.area.id)
      before = row_counts(context)

      assert {:error, {:unsupported, {:source_statements, [^statement]}}} =
               Assistant.prepare(scope, Map.put(supported_input(), "unsupported", [statement]))

      # A guaranteed same-day rule is never inferred from the discretionary
      # statement: the refusal is the only answer, and nothing was written.
      assert row_counts(context) == before
    end

    test "a contradictory rule is refused by native readiness", context do
      assert {:error, {:unsupported, {:contradictory_policy, texts}}} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(%{
                 "scope" => "all_supported",
                 "booking_rules" => [
                   %{"service_id" => nil, "when" => "same_day", "minutes" => 0}
                 ]
               })

      assert texts == ["Enter how many minutes ahead riders must book."]

      # An earlier-day rule with no cut-off time is the same refusal.
      assert {:error,
              {:unsupported, {:contradictory_policy, ["Enter the time riders must book by."]}}} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(%{
                 "scope" => "all_supported",
                 "booking_rules" => [
                   %{"service_id" => nil, "when" => "earlier_day", "days" => 1}
                 ]
               })
    end

    test "explicit hours-only keeps every rule and exposes the excluded prose", context do
      statement = "Same-day booking if the dispatcher permits it."

      assert {:ok, prepared} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(%{
                 "scope" => "hours_only",
                 "hours" => [
                   %{
                     "area_key" => "a1",
                     "service_id" => "weekday",
                     "start" => "08:00",
                     "end" => "17:00"
                   },
                   %{
                     "area_key" => "a2",
                     "service_id" => "weekday",
                     "start" => "09:00",
                     "end" => "15:00"
                   },
                   %{
                     "area_key" => "a1",
                     "service_id" => "saturday",
                     "start" => "18:00",
                     "end" => "01:00"
                   },
                   %{
                     "area_key" => "a2",
                     "service_id" => "saturday",
                     "start" => "09:00",
                     "end" => "15:00"
                   }
                 ],
                 "unsupported" => [statement]
               })

      assert prepared.prepare_scope == :hours_only
      assert prepared.replaced == [:hours]
      assert prepared.unsupported == [statement]

      # Every booking rule is retained exactly as saved, and the patch says so
      # by carrying no booking array at all.
      refute Map.has_key?(prepared.patch, "booking_rules")

      assert Enum.map(
               prepared.candidate.booking_rules,
               &{&1.when, &1.by, &1.business_days, &1.office_service_id}
             ) == [
               {:earlier_day, "16:00", true, "office"},
               {:earlier_day, "12:00", false, nil}
             ]

      assert prepared.booking_rules.changed == []
      assert prepared.booking_rules.unchanged == [0, 1]
      assert prepared.booking_rules.removed == []
      assert prepared.booking_rules.added == []

      # The excluded prose is visible rather than applied, and the retained
      # policy is named as retained.
      assert Enum.any?(prepared.exclusions, &(&1 =~ statement))

      assert Enum.any?(
               prepared.exclusions,
               &(&1 =~ "all 2 booking rule(s) stay exactly as they are")
             )

      # The rider text keeps the saved booking deadlines while the hours move.
      assert "Book Monday trips by 4:00 pm the Friday before" in prepared.rider_text.candidate.deadline_lines

      # A booking array under an hours-only scope contradicts the scope the
      # editor chose rather than being quietly ignored.
      assert {:error, {:unsupported, :booking_rules_in_hours_only}} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(%{
                 "scope" => "hours_only",
                 "hours" => [
                   %{
                     "area_key" => "a1",
                     "service_id" => "weekday",
                     "start" => "08:00",
                     "end" => "17:00"
                   }
                 ],
                 "booking_rules" => [%{"service_id" => nil, "when" => :now}]
               })
    end
  end

  describe "the input is allowlisted and bounded (AC-4)" do
    setup :flex_context

    test "only the allowlisted keys and the two array shapes are accepted", context do
      scope = scope_with_source(context.scope, context.area.id)

      # Naming a service is not part of the input: the service is the accepted
      # source's, never an argument.
      assert {:error, {:invalid_input, {:unknown_key, "service_id"}}} =
               Assistant.prepare(scope, Map.put(supported_input(), "service_id", context.area.id))

      assert {:error, {:invalid_input, {:unknown_key, :scope}}} =
               Assistant.prepare(scope, Map.put(supported_input(), :scope, "all_supported"))

      # A field the native schema does not own is refused even inside a row.
      assert {:error, {:invalid_input, {:booking_rules, 0, :unknown_field}}} =
               Assistant.prepare(scope, %{
                 "scope" => "all_supported",
                 "booking_rules" => [
                   %{"service_id" => nil, "when" => "now", "phone" => "(541) 555-0142"}
                 ]
               })

      assert {:error,
              {:invalid_input,
               {:invalid_hours, 0, ["start Enter a time as HH:MM, between 00:00 and 23:59."]}}} =
               Assistant.prepare(scope, %{
                 "scope" => "all_supported",
                 "hours" => [
                   %{
                     "area_key" => "a1",
                     "service_id" => "weekday",
                     "start" => "7:00 am",
                     "end" => "17:00"
                   }
                 ]
               })

      assert {:error, {:invalid_input, {:hours, 0, :not_a_map}}} =
               Assistant.prepare(scope, %{
                 "scope" => "all_supported",
                 "hours" => [["a1", "weekday", "08:00", "17:00"]]
               })
    end

    test "the scope, the array bounds and the replacement itself are required", context do
      scope = scope_with_source(context.scope, context.area.id)

      hours = [
        %{"area_key" => "a1", "service_id" => "weekday", "start" => "08:00", "end" => "17:00"}
      ]

      assert {:error, {:invalid_input, :not_a_map}} = Assistant.prepare(scope, "hours")
      assert {:error, {:invalid_input, :scope}} = Assistant.prepare(scope, %{"hours" => hours})

      assert {:error, {:invalid_input, :scope}} =
               Assistant.prepare(scope, %{"scope" => "everything", "hours" => hours})

      # A proposal with no replacement array is not a preparation, and an empty
      # array would delete every row at once: neither is ever read as a change.
      assert {:error, {:invalid_input, :no_replacement}} =
               Assistant.prepare(scope, %{"scope" => "all_supported"})

      assert {:error, {:invalid_input, {:hours, :replacement}}} =
               Assistant.prepare(scope, %{"scope" => "all_supported", "hours" => []})

      assert {:error, {:invalid_input, {:booking_rules, :replacement}}} =
               Assistant.prepare(scope, %{"scope" => "all_supported", "booking_rules" => []})

      assert {:error, {:invalid_input, {:hours, :replacement}}} =
               Assistant.prepare(scope, %{
                 "scope" => "all_supported",
                 "hours" => List.duplicate(hours, 101)
               })

      assert {:error, {:invalid_input, :unsupported}} =
               Assistant.prepare(scope, %{
                 "scope" => "all_supported",
                 "hours" => hours,
                 "unsupported" => List.duplicate("too many", 21)
               })

      long = String.duplicate("a", 501)

      assert {:error, {:invalid_input, {:unsupported_statement, ^long}}} =
               Assistant.prepare(scope, %{
                 "scope" => "hours_only",
                 "hours" => hours,
                 "unsupported" => [long]
               })

      assert String.length(long) == 501

      assert {:error, {:invalid_input, {:unsupported_statement, 0, 42}}} =
               Assistant.prepare(scope, %{
                 "scope" => "hours_only",
                 "hours" => hours,
                 "unsupported" => [42]
               })
    end

    test "a scope with no accepted source prepares nothing", context do
      assert {:error, :unavailable} = Assistant.prepare(context.scope, supported_input())
    end
  end

  describe "preparation is pure (AC-4)" do
    setup :flex_context

    test "a read and a preparation write no entity or audit row", context do
      scope = scope_with_source(context.scope, context.area.id)
      before = row_counts(context)

      assert {:ok, _workspace, _evidence} = Assistant.workspace(scope)
      assert {:ok, _prepared} = Assistant.prepare(scope, supported_input())

      assert {:error, {:unsupported, {:contradictory_policy, _}}} =
               Assistant.prepare(scope, %{
                 "scope" => "all_supported",
                 "booking_rules" => [%{"service_id" => nil, "when" => "same_day", "minutes" => 0}]
               })

      assert row_counts(context) == before

      # The saved service is untouched: the candidate never reached the
      # database, so the stored rows and the lock version are the same ones the
      # fixture saved.
      assert {:ok, reloaded} =
               Flex.get_service(context.organization.id, context.version.id, context.area.id)

      assert reloaded.lock_version == context.area.lock_version

      assert Enum.map(reloaded.hours, &{&1.area_key, &1.start, &1.end}) ==
               [
                 {"a1", "07:00", "18:00"},
                 {"a2", "09:00", "15:00"},
                 {"a1", "18:00", "01:00"},
                 {"a2", "09:00", "15:00"}
               ]

      assert Enum.map(reloaded.booking_rules, & &1.by) == ["16:00", "12:00"]
    end

    test "an omitted array is retained, never read as a deletion", context do
      assert {:ok, prepared} =
               context.scope
               |> scope_with_source(context.area.id)
               |> Assistant.prepare(%{
                 "scope" => "all_supported",
                 "hours" => [
                   %{
                     "area_key" => "a1",
                     "service_id" => "weekday",
                     "start" => "08:00",
                     "end" => "17:00"
                   },
                   %{
                     "area_key" => "a2",
                     "service_id" => "weekday",
                     "start" => "09:00",
                     "end" => "15:00"
                   },
                   %{
                     "area_key" => "a1",
                     "service_id" => "saturday",
                     "start" => "18:00",
                     "end" => "01:00"
                   },
                   %{
                     "area_key" => "a2",
                     "service_id" => "saturday",
                     "start" => "09:00",
                     "end" => "15:00"
                   }
                 ]
               })

      assert prepared.replaced == [:hours]
      refute Map.has_key?(prepared.patch, "booking_rules")

      assert prepared.booking_rules.saved == prepared.booking_rules.candidate
      assert length(prepared.booking_rules.candidate) == 2
      assert Enum.any?(prepared.exclusions, &(&1 =~ "booking rule(s) stay exactly as they are"))
    end
  end

  describe "preview/2 compares any candidate of the same service" do
    setup :flex_context

    test "computes the same comparison for a hand-built candidate", context do
      assert {:ok, workspace, _evidence} = Assistant.workspace(context.scope, context.area.id)

      saved = workspace.dependencies.service

      candidate = %{saved | booking_rules: [hd(saved.booking_rules)]}

      assert {:ok, preview} = Assistant.preview(workspace, candidate)

      assert preview.service_id == saved.id
      assert preview.hours.changed == []
      assert preview.hours.unchanged == [0, 1, 2, 3]
      assert preview.hours.added == []
      assert preview.hours.removed == []

      # The removed rule is reported at its saved ordinal with the row that went
      # away, and the rider text keeps the main rule's deadline.
      assert [%{ordinal: 1, row: %{"service_id" => "saturday"}}] = preview.booking_rules.removed
      assert preview.booking_rules.unchanged == [0]

      assert "Book Monday trips by 4:00 pm the Friday before" in preview.rider_text.candidate.deadline_lines

      assert "Saturday booking rule removed" in preview.rider_text.changes
    end

    test "refuses a candidate that is not this workspace's own service", context do
      assert {:ok, workspace, _evidence} = Assistant.workspace(context.scope, context.area.id)
      assert {:ok, other, _evidence} = Assistant.workspace(context.scope, context.detour.id)

      assert {:error, {:invalid_input, :foreign_candidate}} =
               Assistant.preview(workspace, other.dependencies.service)

      assert {:error, {:invalid_input, :foreign_candidate}} =
               Assistant.preview(workspace, %{
                 workspace.dependencies.service
                 | id: Ecto.UUID.generate()
               })
    end
  end

  # --- fixtures ---------------------------------------------------------------

  # The supported proposal: `a1` runs the weekday calendar 08:00–17:00 and one
  # business day must be booked by 15:00. Every other row of both arrays is
  # enumerated unchanged, because the arrays are complete replacements.
  defp supported_input do
    %{
      "scope" => "all_supported",
      "hours" => [
        %{"area_key" => "a1", "service_id" => "weekday", "start" => "08:00", "end" => "17:00"},
        %{"area_key" => "a2", "service_id" => "weekday", "start" => "09:00", "end" => "15:00"},
        %{"area_key" => "a1", "service_id" => "saturday", "start" => "18:00", "end" => "01:00"},
        %{"area_key" => "a2", "service_id" => "saturday", "start" => "09:00", "end" => "15:00"}
      ],
      "booking_rules" => [
        %{
          "service_id" => nil,
          "when" => "earlier_day",
          "days" => 1,
          "by" => "15:00",
          "business_days" => true,
          "office_service_id" => "office"
        },
        %{
          "service_id" => "saturday",
          "when" => "earlier_day",
          "days" => 2,
          "by" => "12:00"
        }
      ]
    }
  end

  defp flex_context(context) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    feed = flex_representative_fixture(organization, version)

    Map.merge(context, %{
      organization: organization,
      version: version,
      area: feed.services.area,
      detour: feed.services.detour,
      audit: flex_audit_fixture(organization.id, version.id),
      scope: scope_for(organization, version)
    })
  end

  defp scope_for(organization, version) do
    user = user_fixture()
    organization_membership_fixture(user, organization)

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "flex_policy",
      version_name: version.name,
      resource_context: Scope.context({:version, version.id})
    }
  end

  # The accepted `flex_policy` snapshot a host freezes after explicit editor
  # acceptance, naming the service the native page had loaded.
  defp scope_with_source(%Scope{} = scope, service_id) do
    {:ok, context} =
      Scope.with_source_snapshot(scope.resource_context, %{
        kind: "flex_policy",
        payload: %{
          "service_id" => service_id,
          "section" => "hours_booking",
          "source" => %{
            "text" => "Weekdays 8 am to 5 pm, booked one business day ahead by 3 pm",
            "label" => "Approved hours policy",
            "accepted" => true
          }
        }
      })

    %{scope | resource_context: context}
  end

  defp fingerprint_of(context) do
    {:ok, workspace, _evidence} = Assistant.workspace(context.scope, context.area.id)
    workspace.fingerprint
  end

  defp source_digest_of(context) do
    context.scope
    |> scope_with_source(context.area.id)
    |> Scope.source_snapshot()
    |> Map.fetch!(:digest)
  end

  defp row_counts(%{organization: organization}) do
    organization_id = organization.id

    %{
      services:
        Repo.aggregate(
          from(s in FlexService, where: s.organization_id == ^organization_id),
          :count
        ),
      areas:
        Repo.aggregate(from(a in FlexArea, where: a.organization_id == ^organization_id), :count),
      calendars:
        Repo.aggregate(from(c in Calendar, where: c.organization_id == ^organization_id), :count),
      calendar_attributes:
        Repo.aggregate(
          from(c in CalendarAttribute, where: c.organization_id == ^organization_id),
          :count
        ),
      calendar_dates:
        Repo.aggregate(
          from(c in CalendarDate, where: c.organization_id == ^organization_id),
          :count
        ),
      audit:
        Repo.aggregate(from(l in ChangeLog, where: l.organization_id == ^organization_id), :count)
    }
  end

  # The office calendar takes Independence Day off, so an office day is not the
  # same set as a weekday.
  defp add_office_exception(context) do
    calendar_date_fixture(context.organization.id, context.version.id, %{
      service_id: "office",
      date: ~D[2026-07-03],
      exception_type: 2
    })
  end

  defp delete_calendar(context, service_id) do
    for schema <- [Calendar, CalendarAttribute, CalendarDate] do
      Repo.delete_all(
        from(row in schema,
          where:
            row.organization_id == ^context.organization.id and
              row.gtfs_version_id == ^context.version.id and row.service_id == ^service_id
        )
      )
    end
  end
end
