defmodule GtfsPlanner.Gtfs.Runs.NumberingTest do
  @moduledoc """
  Merge evidence (EV-7) for CL-8: run numbering follows domain rule 11, so FH-13
  stays rejected.

  The examples here are rule 11's own, which is what the gate names as its
  independence. The two rules are deliberately tested against each other: a
  rebuild takes the **lowest** numeric ID and zeroes it, while a new run takes
  the **highest** and adds one. A single "next number" function would pass
  whichever example it was written for, so the cases that matter are the ones
  where the two answers differ — `["1013", "1030", "A1"]` has a lowest of 1013
  and a highest of 1030, and the two rules must not be confused.

  The focused gate command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_runs08 mix test test/gtfs_planner/gtfs/runs/numbering_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Runs.Numbering

  describe "the rebuild prefix" do
    test "is the lowest numeric run ID with every digit after the first zeroed" do
      # The lowest of 1013 and 1030 is 1013, and 1013 -> 1000. "A1" is not
      # numeric and takes no part in the decision.
      assert Numbering.rebuild_prefix(["1013", "1030", "A1"]) == 1000
    end

    test "keeps a three-digit scheme on three digits" do
      # The rule's own reason for zeroing rather than using a fixed thousands
      # block: 101 -> 100, not 0.
      assert Numbering.rebuild_prefix(["101", "150"]) == 100
    end

    test "zeroes the digits after the first rather than rounding up" do
      # 99999999 -> 90000000, not 10000000: the agency's leading digit survives.
      assert Numbering.rebuild_prefix(["99999999"]) == 90_000_000
    end

    test "is 0 for a single-digit run, which has no scheme to preserve" do
      # With no digits after the first there is nothing to keep, so a one-digit
      # run reads the same as no numeric run at all.
      assert Numbering.rebuild_prefix(["7"]) == 0
      assert Numbering.rebuild_prefix(["7", "X"]) == 0
    end

    test "is 0 when no run is numeric" do
      assert Numbering.rebuild_prefix(["X"]) == 0
      assert Numbering.rebuild_prefix([]) == 0
      assert Numbering.rebuild_prefix(["A1", "N-12", "X9"]) == 0
    end

    test "takes the lowest, not the highest" do
      # The distinction FH-13 names. The highest here is 1030, whose prefix
      # would be 1000 as well, so the case that separates them is a set whose
      # lowest and highest zero differently.
      assert Numbering.rebuild_prefix(["1200", "1013"]) == 1000
      assert Numbering.rebuild_prefix(["150", "101"]) == 100
    end
  end

  describe "the highest numeric run ID" do
    test "is the largest number in use, skipping IDs that are not numbers" do
      assert Numbering.highest_numeric(["1030", "X9"]) == 1030
    end

    test "is 0 when there is none" do
      assert Numbering.highest_numeric([]) == 0
      assert Numbering.highest_numeric(["X", "X9", "N-12"]) == 0
    end
  end

  describe "the next number for a run created outside a rebuild" do
    test "sits one above the highest run in use" do
      # Above 1030, not above 1013 and not from the prefix: a run added by hand
      # must not land on a number another run already has.
      assert Numbering.next_run_id(["1001", "1030", "X9"]) == "1031"
    end

    test "is 1 when nothing numeric is in use" do
      assert Numbering.next_run_id([]) == "1"
    end

    test "is one above a single run" do
      assert Numbering.next_run_id(["1001"]) == "1002"
    end
  end

  describe "the numbers a rebuild produces" do
    test "run from the prefix upward in order" do
      assert Numbering.numeric_after(1000, 3) == ["1001", "1002", "1003"]
    end

    test "are the prefix the rule asks for when the prefix is small" do
      # A three-digit agency rebuilds from 101, not from 1001.
      assert Numbering.numeric_after(Numbering.rebuild_prefix(["101", "150"]), 2) == [
               "101",
               "102"
             ]
    end

    test "are one number for one run" do
      assert Numbering.numeric_after(1000, 1) == ["1001"]
    end
  end

  describe "what is a usable run ID" do
    test "accepts letters, digits and hyphens up to eight characters" do
      assert Numbering.valid_run_id?("1001")
      assert Numbering.valid_run_id?("N-12")
      assert Numbering.valid_run_id?("A")
      assert Numbering.valid_run_id?("12345678")
    end

    test "rejects an empty ID, nine characters, a space and a missing value" do
      refute Numbering.valid_run_id?("")
      refute Numbering.valid_run_id?("ABCDEFGHI")
      refute Numbering.valid_run_id?("1 2")
      refute Numbering.valid_run_id?(nil)
    end

    test "rejects characters outside the format, and any term that is not a string" do
      refute Numbering.valid_run_id?("A_B")
      refute Numbering.valid_run_id?("A.B")
      refute Numbering.valid_run_id?("A B")
      refute Numbering.valid_run_id?(1001)
      refute Numbering.valid_run_id?(%{})
    end
  end

  describe "the two rules together" do
    test "numbering a rebuild produces never an ID the format check rejects" do
      # The widest number the format allows is 99999999. Its rebuild prefix is
      # 90000000 - the rule zeroes the digits after the first rather than
      # rounding up - so the numbers a rebuild produces are still eight
      # characters.
      widest = ["99999999"]
      prefix = Numbering.rebuild_prefix(widest)

      assert prefix == 90_000_000

      for id <- Numbering.numeric_after(prefix, 3) do
        assert String.length(id) == 8
        assert Numbering.valid_run_id?(id)
      end
    end

    test "next_run_id is the one place the rule can pass the format" do
      # A day type already holding 99999999 is offered a nine-character number.
      # The rule does not say what to do about that, and this module does not
      # invent an answer: a silent wrap back to a low number would collide with a
      # run already in use, so the overflow is reported rather than hidden.
      overflow = Numbering.next_run_id(["99999999"])

      assert overflow == "100000000"
      refute Numbering.valid_run_id?(overflow)
    end

    test "a rebuild starting from the prefix does not continue from the highest" do
      # FH-13: the wrong answer here is 1031, continuing from the highest.
      existing = ["1013", "1030"]
      rebuilt = Numbering.numeric_after(Numbering.rebuild_prefix(existing), 2)

      assert rebuilt == ["1001", "1002"]
      refute Numbering.next_run_id(existing) in rebuilt
    end
  end
end
