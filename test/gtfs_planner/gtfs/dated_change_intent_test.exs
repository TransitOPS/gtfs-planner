defmodule GtfsPlanner.Gtfs.DatedChangeIntentTest do
  @moduledoc """
  Merge evidence (EV-1) for `DatedChangePlan.normalize_intent/2` and
  `accept_intent/2`: the explicit-date, signed-shift, selection-bound acceptance
  and its refusals.

  Expectations are derived from the acceptance cases and the A36 plan-only
  decision, not from a second invocation of the module under test:

    * 2026-11-02 through 2026-11-13 is an explicit inclusive interval with
      four-digit years, so it normalizes to those two `Date` structs and a
      `+300` shift is the integer 300 service-day seconds. A missing year, a
      two-digit year, a non-ISO ordering or `last_date` before `first_date`
      names the offending field, and no date is inferred.
    * The accepted source is the seven bound values plus `schema_version` 1 and
      a lowercase hex `input_digest` over their canonical ordered JSON. The
      digest literal below was computed by hand from that canonical form, so
      the module cannot pass by hashing its own struct.
    * `+300` signed shift is a five-minute move of the same service-day seconds;
      the range boundary `-86400..86400` is inclusive, and `86401` is refused.
    * Identity, version, digest and accepted flags are server-owned: submitting
      one refuses the request instead of quietly reading the value.
    * Acceptance is bound to the *current* selection, so a selection that
      changed after normalization is `{:error, :selection_changed}` and no
      accepted source survives. A draft carrying a forged `input_digest` is
      `{:error, :invalid_draft}`.

  No test here runs a server, a provider or a domain writer: this slice is a
  pure intent library (INV-1).
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.DatedChangePlan

  @trip_a "11111111-1111-4111-8111-111111111111"
  @trip_b "22222222-2222-4222-8222-222222222222"
  @trip_c "33333333-3333-4333-8333-333333333333"
  @approval "Approved by the transit board on 2026-09-30 for the November detour."

  # sha256 of
  # [["schema_version",1],["trip_ids",[<@trip_a>,<@trip_b>]],["first_date","2026-11-02"],
  #  ["last_date","2026-11-13"],["delta_seconds",300],["approval_note",<@approval>],
  #  ["source_label",null]]
  @input_digest "5cee0234dc28441bcd687cc72b2d154086ab0aa97d9ce6051eb664100e6b0f4a"

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        "first_date" => "2026-11-02",
        "last_date" => "2026-11-13",
        "delta_seconds" => "300",
        "approval_note" => @approval,
        "source_label" => ""
      },
      overrides
    )
  end

  describe "normalize_intent/2 explicit dates and signed shift" do
    test "normalizes the inclusive interval and the signed shift" do
      assert {:ok, draft} = DatedChangePlan.normalize_intent(params(), [@trip_b, @trip_a])

      assert draft.first_date == ~D[2026-11-02]
      assert draft.last_date == ~D[2026-11-13]
      assert draft.delta_seconds == 300
      assert draft.approval_note == @approval
      assert is_nil(draft.source_label)
      assert draft.trip_ids == [@trip_a, @trip_b]
    end

    test "accepts atom keys, a signed negative shift and a source label" do
      atom_params = %{
        first_date: ~D[2026-11-02],
        last_date: ~D[2026-11-13],
        delta_seconds: -300,
        approval_note: "  #{@approval}  ",
        source_label: "  Board packet 42  "
      }

      assert {:ok, draft} = DatedChangePlan.normalize_intent(atom_params, [@trip_a])

      assert draft.delta_seconds == -300
      assert draft.approval_note == @approval
      assert draft.source_label == "Board packet 42"
    end

    test "refuses ambiguous or non-ISO dates without inferring a year" do
      for value <- [
            "11-02",
            "11/02/2026",
            "02-11-2026",
            "26-11-02",
            "2026-11-2",
            "November 2 2026"
          ] do
        assert {:error, errors} =
                 DatedChangePlan.normalize_intent(params(%{"first_date" => value}), [@trip_a])

        assert [message] = errors.first_date
        assert message =~ "YYYY-MM-DD"
      end
    end

    test "refuses a real-looking but impossible date" do
      assert {:error, %{first_date: [message]}} =
               DatedChangePlan.normalize_intent(params(%{"first_date" => "2026-13-01"}), [@trip_a])

      assert message =~ "real calendar date"
    end

    test "refuses a reversed interval and reports only the ordering" do
      assert {:error, errors} =
               DatedChangePlan.normalize_intent(
                 params(%{"first_date" => "2026-11-13", "last_date" => "2026-11-02"}),
                 [@trip_a]
               )

      assert errors == %{last_date: ["The last date must not be before the first date."]}
    end

    test "accepts a single-day interval" do
      assert {:ok, draft} =
               DatedChangePlan.normalize_intent(
                 params(%{"first_date" => "2026-11-11", "last_date" => "2026-11-11"}),
                 [@trip_a]
               )

      assert draft.first_date == draft.last_date
    end

    test "refuses a shift outside the inclusive range and a fractional or blank shift" do
      for value <- ["86401", "-86401", "300.5", "5 minutes", "", "+", "3e2"] do
        assert {:error, %{delta_seconds: [message]}} =
                 DatedChangePlan.normalize_intent(params(%{"delta_seconds" => value}), [@trip_a])

        assert message =~ "whole-second shift"
      end
    end

    test "accepts the exact range boundaries" do
      for value <- ["86400", "-86400"] do
        assert {:ok, draft} =
                 DatedChangePlan.normalize_intent(params(%{"delta_seconds" => value}), [@trip_a])

        assert draft.delta_seconds == String.to_integer(value)
      end
    end
  end

  describe "normalize_intent/2 supplied provenance" do
    test "refuses a blank approval note and an over-long note" do
      assert {:error, %{approval_note: [message]}} =
               DatedChangePlan.normalize_intent(params(%{"approval_note" => "   "}), [@trip_a])

      assert message =~ "approval note"

      assert {:error, %{approval_note: [message]}} =
               DatedChangePlan.normalize_intent(
                 params(%{"approval_note" => String.duplicate("a", 2_001)}),
                 [@trip_a]
               )

      assert message =~ "2000 characters"
    end

    test "accepts an approval note of exactly the cap" do
      note = String.duplicate("a", 2_000)

      assert {:ok, draft} =
               DatedChangePlan.normalize_intent(params(%{"approval_note" => note}), [@trip_a])

      assert draft.approval_note == note
    end

    test "refuses an over-long source label and allows an absent one" do
      assert {:error, %{source_label: [message]}} =
               DatedChangePlan.normalize_intent(
                 params(%{"source_label" => String.duplicate("b", 201)}),
                 [@trip_a]
               )

      assert message =~ "200 characters"

      assert {:ok, draft} =
               DatedChangePlan.normalize_intent(
                 params(%{}) |> Map.delete("source_label"),
                 [@trip_a]
               )

      assert is_nil(draft.source_label)
    end
  end

  describe "normalize_intent/2 selection bounds" do
    test "refuses an empty selection" do
      assert {:error, %{selected_trip_ids: [message]}} =
               DatedChangePlan.normalize_intent(params(), [])

      assert message =~ "at least one trip"
    end

    test "refuses a non-UUID, a repeated or an over-cap selection" do
      assert {:error, %{selected_trip_ids: [message]}} =
               DatedChangePlan.normalize_intent(params(), ["not-a-uuid"])

      assert message =~ "identifiers"

      assert {:error, %{selected_trip_ids: [message]}} =
               DatedChangePlan.normalize_intent(params(), [@trip_a, @trip_a])

      assert message =~ "identifiers"

      over_cap =
        for index <- 0..100 do
          "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0")
        end

      assert {:error, %{selected_trip_ids: [message]}} =
               DatedChangePlan.normalize_intent(params(), over_cap)

      assert message =~ "at most 100"
    end

    test "refuses a selection that is not a list at all" do
      assert {:error, %{selected_trip_ids: [message]}} =
               DatedChangePlan.normalize_intent(params(), @trip_a)

      assert message =~ "identifiers"
    end
  end

  describe "normalize_intent/2 refuses client-supplied server fields" do
    test "refuses forged identity, version, digest and accepted fields" do
      for field <- ~w(route_id organization_id user_id gtfs_version_id pack_id) do
        assert {:error, %{base: [message]}} =
                 DatedChangePlan.normalize_intent(params(%{field => @trip_a}), [@trip_a])

        assert message =~ "#{field} is set by the server"
      end

      for field <- ~w(input_digest digest dependency_digest accepted schema_version) do
        assert {:error, %{base: [message]}} =
                 DatedChangePlan.normalize_intent(params(%{field => "forged"}), [@trip_a])

        assert message =~ "cannot be submitted"
      end
    end

    test "names every forged field in one refusal" do
      assert {:error, %{base: [message]}} =
               DatedChangePlan.normalize_intent(
                 params(%{"route_id" => "r", "organization_id" => "o", "accepted" => true}),
                 [@trip_a]
               )

      assert message =~ "accepted, organization_id, route_id"
    end

    test "refuses before any field validation, so a forged field never yields a draft" do
      assert {:error, errors} =
               DatedChangePlan.normalize_intent(
                 params(%{"first_date" => "11-02", "input_digest" => "forged"}),
                 [@trip_a]
               )

      assert Map.keys(errors) == [:base]
    end
  end

  describe "accept_intent/2 accepted source" do
    setup do
      {:ok, draft} = DatedChangePlan.normalize_intent(params(), [@trip_b, @trip_a])
      %{draft: draft}
    end

    test "binds the seven values, schema_version and the deterministic digest", %{draft: draft} do
      assert {:ok, accepted} = DatedChangePlan.accept_intent(draft, [@trip_a, @trip_b])

      assert accepted.schema_version == 1
      assert accepted.trip_ids == [@trip_a, @trip_b]
      assert accepted.first_date == ~D[2026-11-02]
      assert accepted.last_date == ~D[2026-11-13]
      assert accepted.delta_seconds == 300
      assert accepted.approval_note == @approval
      assert is_nil(accepted.source_label)
      assert accepted.input_digest == @input_digest
    end

    test "is identical for the same normalized intent regardless of selection order", %{
      draft: draft
    } do
      assert {:ok, first} = DatedChangePlan.accept_intent(draft, [@trip_a, @trip_b])
      assert {:ok, second} = DatedChangePlan.accept_intent(draft, %{trip_ids: [@trip_b, @trip_a]})

      assert first == second
    end

    test "carries no identity, route, version or accepted flag", %{draft: draft} do
      assert {:ok, accepted} = DatedChangePlan.accept_intent(draft, [@trip_a, @trip_b])

      assert Map.keys(accepted) |> Enum.sort() ==
               [
                 :approval_note,
                 :delta_seconds,
                 :first_date,
                 :input_digest,
                 :last_date,
                 :schema_version,
                 :source_label,
                 :trip_ids
               ]
    end

    test "changes the digest when any bound value changes" do
      for {field, value} <- [
            {:delta_seconds, 600},
            {:first_date, ~D[2026-11-03]},
            {:last_date, ~D[2026-11-14]},
            {:approval_note, "Different note."},
            {:source_label, "Board packet 42"}
          ] do
        {:ok, draft} = DatedChangePlan.normalize_intent(params(), [@trip_a])
        {:ok, accepted} = DatedChangePlan.accept_intent(draft, [@trip_a])
        changed = Map.put(draft, field, value)

        assert {:ok, other} = DatedChangePlan.accept_intent(changed, [@trip_a])
        refute other.input_digest == accepted.input_digest
      end
    end
  end

  describe "accept_intent/2 refuses a stale or forged draft" do
    setup do
      {:ok, draft} = DatedChangePlan.normalize_intent(params(), [@trip_a, @trip_b])
      %{draft: draft}
    end

    test "a changed current selection invalidates acceptance", %{draft: draft} do
      assert DatedChangePlan.accept_intent(draft, [@trip_a]) == {:error, :selection_changed}

      assert DatedChangePlan.accept_intent(draft, [@trip_a, @trip_b, @trip_c]) ==
               {:error, :selection_changed}

      assert DatedChangePlan.accept_intent(draft, []) == {:error, :selection_changed}
    end

    test "a cleared and reselected trip invalidates acceptance", %{draft: draft} do
      assert {:ok, _accepted} = DatedChangePlan.accept_intent(draft, [@trip_b, @trip_a])

      {:ok, redrafted} = DatedChangePlan.normalize_intent(params(), [@trip_c, @trip_a])

      assert DatedChangePlan.accept_intent(redrafted, [@trip_c, @trip_a, @trip_b]) ==
               {:error, :selection_changed}
    end

    test "a draft carrying a forged digest, identity or accepted flag is invalid", %{draft: draft} do
      for key <- [:input_digest, :accepted, :route_id, :organization_id, :schema_version] do
        assert DatedChangePlan.accept_intent(Map.put(draft, key, "forged"), [@trip_a, @trip_b]) ==
                 {:error, :invalid_draft}
      end
    end

    test "a missing or malformed draft is invalid", %{draft: draft} do
      assert DatedChangePlan.accept_intent(Map.delete(draft, :approval_note), [@trip_a, @trip_b]) ==
               {:error, :invalid_draft}

      assert DatedChangePlan.accept_intent(Map.put(draft, :delta_seconds, 86_401), [
               @trip_a,
               @trip_b
             ]) ==
               {:error, :invalid_draft}

      assert DatedChangePlan.accept_intent(%{draft | first_date: "2026-11-02"}, [@trip_a, @trip_b]) ==
               {:error, :invalid_draft}

      assert DatedChangePlan.accept_intent(%{draft | trip_ids: [@trip_b, @trip_a]}, [
               @trip_a,
               @trip_b
             ]) ==
               {:error, :invalid_draft}

      assert DatedChangePlan.accept_intent("not a draft", [@trip_a]) ==
               {:error, :invalid_draft}
    end

    test "a non-list current selection is invalid rather than accepted", %{draft: draft} do
      assert DatedChangePlan.accept_intent(draft, "everything") == {:error, :invalid_selection}
    end
  end
end
