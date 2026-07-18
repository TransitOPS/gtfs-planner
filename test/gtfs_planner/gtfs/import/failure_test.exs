defmodule GtfsPlanner.Gtfs.Import.FailureTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Import.{Failure, ParseError}

  describe "from_error/2 reason normalization" do
    test "maps a ParseError to its bounded reason code and sanitized file/row" do
      error = %ParseError{file: "levels.txt", row: 27, reason: :duplicate_header}

      failure = Failure.from_error(error, phase: :phase_1)

      assert failure.reason_code == "duplicate_header"
      assert failure.failed_file == "levels.txt"
      assert failure.failed_row == 27
      assert failure.reason_code in Failure.reason_codes()
    end

    test "maps an unknown ParseError reason to a fixed fallback code" do
      error = %ParseError{file: "stops.txt", reason: :some_future_reason}

      failure = Failure.from_error(error, phase: :phase_1)

      assert failure.reason_code == "unexpected_parser_failure"
      assert failure.reason_code in Failure.reason_codes()
    end

    test "maps a batch row-conversion error without storing the message" do
      error = %{file: "stop_times.txt", row: 2102, reason: "value is not a number: not_a_number"}

      failure = Failure.from_error(error, phase: :phase_2, outcome: :partial)

      assert failure.reason_code == "row_invalid"
      assert failure.failed_file == "stop_times.txt"
      assert failure.failed_row == 2102
      refute serialized_contains?(failure, "not_a_number")
    end

    test "maps an Ecto constraint error map without storing the SQL message" do
      error = %{
        file: "levels.txt",
        constraint: "levels_org_version_level_id_index",
        message: "ERROR 23505 (unique_violation) duplicate key value violates unique constraint"
      }

      failure = Failure.from_error(error, phase: :phase_1)

      assert failure.reason_code == "constraint_violation"
      assert failure.failed_file == "levels.txt"
      assert failure.failed_row == nil
      refute serialized_contains?(failure, "23505")
      refute serialized_contains?(failure, "unique constraint")
    end

    test "maps a Postgrex constraint map without storing the SQL message" do
      error = %{
        file: "stops.txt",
        postgres_error: "23503",
        constraint: "stops_level_id_fkey",
        message: "ERROR 23503 (foreign_key_violation) insert or update on table violates"
      }

      failure = Failure.from_error(error, phase: :phase_1)

      assert failure.reason_code == "constraint_violation"
      assert failure.failed_file == "stops.txt"
      refute serialized_contains?(failure, "23503")
      refute serialized_contains?(failure, "foreign_key_violation")
    end

    test "maps a generic database exception without storing the message" do
      error = %{file: "shapes.txt", error: "** (RuntimeError) boom at line 42"}

      failure = Failure.from_error(error, phase: :phase_2)

      assert failure.reason_code == "database_error"
      assert failure.failed_file == "shapes.txt"
      refute serialized_contains?(failure, "RuntimeError")
      refute serialized_contains?(failure, "line 42")
    end

    test "maps extension missing-reference and image errors to fixed codes" do
      missing = Failure.from_error({:missing_references, %{stops: ["X"]}}, phase: :extensions)
      assert missing.reason_code == "missing_references"

      missing_binary =
        Failure.from_error(
          {:image_restore_failed,
           {:missing_binary, "_pathways_extensions/diagrams/32095/lvl.png"}},
          phase: :extensions
        )

      assert missing_binary.reason_code == "missing_image"
      refute serialized_contains?(missing_binary, "_pathways_extensions")

      write_failed =
        Failure.from_error(
          {:image_restore_failed,
           {:write_failed, "_pathways_extensions/diagrams/32095/lvl.png", :unsafe_path}},
          phase: :extensions
        )

      assert write_failed.reason_code == "image_write_failed"
      refute serialized_contains?(write_failed, "_pathways_extensions")
    end

    test "normalizes an unknown term to a fixed reason code with no raw term" do
      failure = Failure.from_error({:totally, :unexpected, %{nested: "secret"}}, phase: :phase_2)

      assert failure.reason_code == "unknown_error"
      assert failure.reason_code in Failure.reason_codes()
      assert failure.failed_file == nil
      assert failure.failed_row == nil
      refute serialized_contains?(failure, "secret")
    end

    test "strips directory components from a file so no filesystem path leaks" do
      error = %{file: "/var/data/uploads/stop_times.txt", row: 3, reason: "bad"}

      failure = Failure.from_error(error, phase: :phase_2)

      assert failure.failed_file == "stop_times.txt"
      refute serialized_contains?(failure, "/var/data")
    end

    test "drops a non-positive row so the persisted failed_row is valid or nil" do
      error = %{file: "levels.txt", row: 0, reason: "bad"}

      failure = Failure.from_error(error, phase: :phase_1)

      assert failure.failed_row == nil
    end

    test "carries phase, outcome, counts, and certainty from options" do
      failure =
        Failure.from_error(%ParseError{file: "a.txt", reason: :wrong_field_count},
          phase: :phase_2,
          outcome: :partial,
          committed_counts: %{stop_times: 2000, levels: 1},
          counts_complete: false
        )

      assert failure.phase == :phase_2
      assert failure.outcome == :partial
      assert failure.committed_counts == %{stop_times: 2000, levels: 1}
      assert failure.counts_complete == false
    end
  end

  describe "to_run_attrs/1" do
    test "emits only bounded, sanitized persisted attributes" do
      failure =
        Failure.from_error(%{file: "stop_times.txt", row: 2102, reason: "boom"},
          phase: :phase_2,
          outcome: :partial,
          committed_counts: %{stop_times: 2000},
          counts_complete: true
        )

      attrs = Failure.to_run_attrs(failure)

      assert Map.keys(attrs) |> Enum.sort() ==
               [
                 :committed_counts,
                 :counts_complete,
                 :failed_file,
                 :failed_row,
                 :phase,
                 :reason_code
               ]

      # State, lease, and timestamps are owned by the caller and must not appear.
      refute Map.has_key?(attrs, :state)
      refute Map.has_key?(attrs, :lease_token)
      refute Map.has_key?(attrs, :started_at)

      assert attrs.phase == "phase_2"
      assert attrs.reason_code == "row_invalid"
      assert attrs.failed_file == "stop_times.txt"
      assert attrs.failed_row == 2102
      assert attrs.counts_complete == true
      assert attrs.committed_counts == %{stop_times: 2000}
    end

    test "never serializes row contents, messages, SQL, traces, or paths" do
      failure =
        Failure.from_error(
          %{
            file: "/uploads/levels.txt",
            constraint: "levels_index",
            message: "ERROR 23505 duplicate key at stack trace line 99"
          },
          phase: :phase_1
        )

      attrs = Failure.to_run_attrs(failure)

      serialized = inspect(attrs)
      refute serialized =~ "23505"
      refute serialized =~ "stack trace"
      refute serialized =~ "/uploads"
      assert attrs.failed_file == "levels.txt"
    end
  end

  # A failure must only ever serialize its bounded fields. This helper inspects
  # the full struct to guard against accidental leakage of raw terms.
  defp serialized_contains?(%Failure{} = failure, needle) do
    inspect(failure) =~ needle
  end
end
