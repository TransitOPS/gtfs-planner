defmodule GtfsPlanner.Alerts.FeedPeriodsTest do
  @moduledoc """
  Step 10: `FeedPeriods` converts accepted civil timing into the explicit UTC
  periods a public realtime feed carries (AC-12, CL-7).

  Every expected instant below is a literal worked out by hand from the zone
  rules, not a value recomputed by the module under test: the whole point of
  these periods is that a zone database update cannot silently reinterpret them.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Alerts.FeedPeriods
  alias GtfsPlanner.Alerts.TimingAnswer

  @new_york "America/New_York"
  @chicago "America/Chicago"

  describe "compile/3 with an all-day answer" do
    test "a spring-forward day ends at civil midnight, 23 hours after it starts" do
      assert {:ok, %{periods: [%{start: 1_772_946_000, end: 1_773_028_800}] = periods}} =
               FeedPeriods.compile(
                 timing(start_date: ~D[2026-03-08], all_day: true, time_zone: @new_york),
                 @new_york
               )

      assert [%{start: start, end: finish}] = periods
      assert finish - start == 82_800
      refute finish - start == 86_400
    end

    test "a fall-back day is the 25 hours the agency actually lived through" do
      assert {:ok, %{periods: [%{start: 1_793_505_600, end: 1_793_595_600}] = periods}} =
               FeedPeriods.compile(
                 timing(start_date: ~D[2026-11-01], all_day: true, time_zone: @new_york),
                 @new_york
               )

      assert [%{start: start, end: finish}] = periods
      assert finish - start == 90_000
    end
  end

  describe "compile/3 with a timed answer" do
    test "an overnight end lands on the next civil date, nine hours across a fall-back" do
      assert {:ok, %{periods: [%{start: 1_793_581_200, end: 1_793_613_600}]}} =
               FeedPeriods.compile(
                 timing(
                   start_date: ~D[2026-11-01],
                   start_time: ~T[20:00:00],
                   end_kind: :confirmed,
                   end_date: ~D[2026-11-01],
                   end_time: ~T[05:00:00],
                   time_zone: @new_york
                 ),
                 @new_york
               )
    end

    test "an unknown end stays open and a check-in never expires the alert" do
      for end_kind <- [:unknown, :estimated, nil] do
        assert {:ok, %{periods: [%{start: 1_777_636_800, end: nil}]}} =
                 FeedPeriods.compile(
                   timing(
                     start_date: ~D[2026-05-01],
                     start_time: ~T[08:00:00],
                     end_kind: end_kind,
                     end_time: ~T[12:00:00],
                     check_in_at: ~N[2026-05-01 10:00:00],
                     time_zone: @new_york
                   ),
                   @new_york
                 )
      end
    end

    test "a confirmed end closes the period" do
      assert {:ok, %{periods: [%{start: 1_777_636_800, end: 1_777_651_200}]}} =
               FeedPeriods.compile(
                 timing(
                   start_date: ~D[2026-05-01],
                   start_time: ~T[08:00:00],
                   end_kind: :confirmed,
                   end_date: ~D[2026-05-01],
                   end_time: ~T[12:00:00],
                   time_zone: @new_york
                 ),
                 @new_york
               )
    end
  end

  describe "compile/3 with a daylight saving gap" do
    test "a reading the zone skipped is refused with the window that does exist" do
      assert {:error, [error]} =
               FeedPeriods.compile(
                 timing(
                   start_date: ~D[2026-03-08],
                   start_time: ~T[02:30:00],
                   end_kind: :unknown,
                   time_zone: @new_york
                 ),
                 @new_york
               )

      assert error.field == :start_time
      assert error.key == nil
      assert error.choices == []
      assert error.message =~ "does not exist on 2026-03-08 in America/New_York"
      assert error.message =~ "2 AM and 3 AM"
    end

    test "a gap in the end is refused against the end field" do
      assert {:error, [error]} =
               FeedPeriods.compile(
                 timing(
                   start_date: ~D[2026-03-07],
                   start_time: ~T[20:00:00],
                   end_kind: :confirmed,
                   end_date: ~D[2026-03-08],
                   end_time: ~T[02:30:00],
                   time_zone: @new_york
                 ),
                 @new_york
               )

      assert error.field == :end_time
      assert error.message =~ "does not exist on 2026-03-08 in America/New_York"
    end
  end

  describe "compile/3 with a daylight saving fold" do
    test "an unresolved reading returns both alternatives keyed to that occurrence and zone" do
      assert {:error, [error]} =
               FeedPeriods.compile(
                 timing(
                   start_date: ~D[2026-11-01],
                   start_time: ~T[01:30:00],
                   end_kind: :unknown,
                   time_zone: @new_york
                 ),
                 @new_york
               )

      key = FeedPeriods.choice_key(~N[2026-11-01 01:30:00], @new_york)

      assert error.field == :start_time
      assert error.key == key
      assert error.message =~ "occurs twice on 2026-11-01 in America/New_York"
      assert error.message =~ "Choose which of these two instants applies"

      assert error.choices == [
               %{key: key, offset_seconds: -14_400, start: 1_793_511_000},
               %{key: key, offset_seconds: -18_000, start: 1_793_514_600}
             ]
    end

    test "a saved choice resolves the reading and nothing else does" do
      key = FeedPeriods.choice_key(~N[2026-11-01 01:30:00], @new_york)
      answer = timing(start_date: ~D[2026-11-01], start_time: ~T[01:30:00], end_kind: :unknown)

      assert {:ok, %{periods: [%{start: 1_793_511_000}]}} =
               FeedPeriods.compile(answer, @new_york, %{key => -14_400})

      assert {:ok, %{periods: [%{start: 1_793_514_600}]}} =
               FeedPeriods.compile(answer, @new_york, %{key => -18_000})
    end

    test "a saved offset that is no longer one of the two is refused rather than assumed" do
      key = FeedPeriods.choice_key(~N[2026-11-01 01:30:00], @new_york)

      assert {:error, [error]} =
               FeedPeriods.compile(
                 timing(start_date: ~D[2026-11-01], start_time: ~T[01:30:00], end_kind: :unknown),
                 @new_york,
                 %{key => -20_000}
               )

      assert length(error.choices) == 2
    end

    test "a choice saved for another zone or another reading does not resolve this one" do
      answer = timing(start_date: ~D[2026-11-01], start_time: ~T[01:30:00], end_kind: :unknown)
      other_zone_key = FeedPeriods.choice_key(~N[2026-11-01 01:30:00], @chicago)
      other_reading_key = FeedPeriods.choice_key(~N[2026-11-01 02:30:00], @new_york)

      assert {:error, [_error]} =
               FeedPeriods.compile(answer, @new_york, %{other_zone_key => -18_000})

      assert {:error, [_error]} =
               FeedPeriods.compile(answer, @new_york, %{other_reading_key => -18_000})
    end

    test "one ambiguous occurrence refuses the whole compile, not just its own period" do
      # Thursday 2026-10-29 01:30 is unambiguous and resolves, but the Sunday
      # 2026-11-01 01:30 it shares a week with is not, so nothing is published.
      assert {:error, [error]} =
               FeedPeriods.compile(
                 timing(
                   pattern: :weekly,
                   first_date: ~D[2026-10-28],
                   weeks: 1,
                   weekdays: [4, 7],
                   start_time: ~T[01:30:00],
                   end_kind: :unknown,
                   time_zone: @new_york
                 ),
                 @new_york
               )

      assert error.key == FeedPeriods.choice_key(~N[2026-11-01 01:30:00], @new_york)

      key = error.key

      assert {:ok, %{periods: [%{start: thursday}, %{start: sunday}]}} =
               FeedPeriods.compile(
                 timing(
                   pattern: :weekly,
                   first_date: ~D[2026-10-28],
                   weeks: 1,
                   weekdays: [4, 7],
                   start_time: ~T[01:30:00],
                   end_kind: :unknown,
                   time_zone: @new_york
                 ),
                 @new_york,
                 %{key => -18_000}
               )

      assert thursday == 1_793_251_800
      assert sunday == 1_793_514_600
    end
  end

  describe "compile/3 with a repeating answer" do
    test "an over-long span is refused with the bound that refused it" do
      assert {:error, [error]} =
               FeedPeriods.compile(
                 timing(
                   pattern: :continuous,
                   first_date: ~D[2026-01-01],
                   last_date: ~D[2027-06-01],
                   all_day: true,
                   time_zone: @new_york
                 ),
                 @new_york
               )

      assert error.field == :timing
      assert error.message =~ "366 days or 400 dates"
    end

    test "an over-long occurrence count is refused even while its span is legal" do
      added_dates = Date.range(~D[2027-01-04], ~D[2027-03-04]) |> Enum.to_list()

      assert {:error, [error]} =
               FeedPeriods.compile(
                 timing(
                   pattern: :weekly,
                   first_date: ~D[2026-01-05],
                   weeks: 52,
                   weekdays: [1, 2, 3, 4, 5, 6, 7],
                   added_dates: added_dates,
                   all_day: true,
                   time_zone: @new_york
                 ),
                 @new_york
               )

      assert error.message =~ "366 days or 400 dates"
    end

    test "an incomplete answer is refused instead of publishing a partial period" do
      assert {:error, [error]} =
               FeedPeriods.compile(
                 timing(pattern: :continuous, first_date: ~D[2026-01-01], time_zone: @new_york),
                 @new_york
               )

      assert error.field == :timing
      assert error.message =~ "not complete enough to publish"
    end
  end

  describe "compile/3 with the notice boundary" do
    test "a notice date the operator chose is the boundary" do
      assert {:ok, %{notice_at: 1_792_900_800, periods: _periods}} =
               FeedPeriods.compile(
                 timing(
                   start_date: ~D[2026-11-01],
                   start_time: ~T[20:00:00],
                   end_kind: :unknown,
                   notice_on: ~D[2026-10-25],
                   time_zone: @new_york
                 ),
                 @new_york
               )
    end

    test "without a chosen notice date the boundary is a week before the first date" do
      assert {:ok, %{notice_at: 1_772_341_200}} =
               FeedPeriods.compile(
                 timing(start_date: ~D[2026-03-08], all_day: true, time_zone: @new_york),
                 @new_york
               )
    end
  end

  describe "compile/3 with the zone" do
    test "an explicit zone wins over the zone the alert was saved with" do
      answer =
        timing(
          start_date: ~D[2026-05-01],
          start_time: ~T[08:00:00],
          end_kind: :unknown,
          time_zone: @chicago
        )

      assert {:ok, %{periods: [%{start: chicago_start}]}} = FeedPeriods.compile(answer, @new_york)
      assert {:ok, %{periods: [%{start: retained_start}]}} = FeedPeriods.compile(answer, nil)
      assert chicago_start == 1_777_636_800
      assert retained_start == 1_777_640_400
    end

    test "a missing, blank or unknown zone is refused rather than read as UTC" do
      answer = timing(start_date: ~D[2026-05-01], start_time: ~T[08:00:00], end_kind: :unknown)

      assert {:error, [missing]} = FeedPeriods.compile(%{answer | time_zone: nil}, nil)
      assert missing.field == :time_zone
      assert missing.message =~ "Choose the timezone"

      assert {:error, [blank]} = FeedPeriods.compile(%{answer | time_zone: "  "}, "   ")
      assert blank.field == :time_zone

      assert {:error, [unknown]} = FeedPeriods.compile(answer, "Mars/Olympus")
      assert unknown.field == :time_zone
      assert unknown.message =~ "not a known timezone"
    end
  end

  describe "service_instant/4" do
    test "a service time past 24:00 keeps its service date and lands on the next civil date" do
      assert FeedPeriods.service_instant(~D[2026-03-07], "25:30:00", @new_york) ==
               {:ok, 1_772_951_400}

      assert FeedPeriods.service_instant(~D[2026-03-07], 91_800, @new_york) ==
               {:ok, 1_772_951_400}
    end

    test "the same clock reading on the service date itself is a different instant" do
      assert FeedPeriods.service_instant(~D[2026-03-07], "01:30:00", @new_york) ==
               {:ok, 1_772_865_000}
    end

    test "an ambiguous service time is refused until an offset is chosen" do
      key = FeedPeriods.choice_key(~N[2026-11-01 01:30:00], @new_york)

      assert {:error, [%{choices: choices}]} =
               FeedPeriods.service_instant(~D[2026-11-01], "01:30:00", @new_york)

      assert [%{offset_seconds: -14_400, start: 1_793_511_000} | _rest] = choices

      assert FeedPeriods.service_instant(~D[2026-11-01], "01:30:00", @new_york, %{key => -18_000}) ==
               {:ok, 1_793_514_600}
    end

    test "a malformed service time and an unknown zone are refused" do
      assert {:error, [error]} = FeedPeriods.service_instant(~D[2026-03-07], "25:0:0", @new_york)
      assert error.field == :start_time

      assert {:error, [error]} =
               FeedPeriods.service_instant(~D[2026-03-07], "01:30:00", "Mars/Olympus")

      assert error.field == :time_zone
    end
  end

  defp timing(attrs) do
    struct!(%TimingAnswer{time_zone: @new_york}, attrs)
  end
end
