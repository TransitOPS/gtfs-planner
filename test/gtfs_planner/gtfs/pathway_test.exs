defmodule GtfsPlanner.Gtfs.PathwayTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [get_field: 2]

  alias GtfsPlanner.Gtfs.Pathway

  @exit_gate 7

  defp pathway(attrs) do
    struct!(
      %Pathway{
        pathway_id: "pw-1",
        pathway_mode: 1,
        is_bidirectional: true,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate(),
        from_stop_id: "from",
        to_stop_id: "to"
      },
      attrs
    )
  end

  describe "changeset/2 for exit gates" do
    test "stores a new two-way exit gate as one-way" do
      attrs = %{
        pathway_id: "pw-1",
        pathway_mode: @exit_gate,
        is_bidirectional: true,
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate(),
        from_stop_id: "from",
        to_stop_id: "to"
      }

      changeset = Pathway.changeset(%Pathway{}, attrs)

      assert changeset.valid?
      assert get_field(changeset, :is_bidirectional) == false
    end

    test "stores an existing walkway switched to exit gate as one-way" do
      changeset =
        Pathway.changeset(pathway(%{pathway_mode: 1, is_bidirectional: true}), %{
          pathway_mode: @exit_gate
        })

      assert changeset.valid?
      assert get_field(changeset, :is_bidirectional) == false
    end

    test "keeps an existing exit gate one-way when only is_bidirectional is set" do
      changeset =
        Pathway.changeset(pathway(%{pathway_mode: @exit_gate, is_bidirectional: false}), %{
          is_bidirectional: true
        })

      assert changeset.valid?
      assert get_field(changeset, :is_bidirectional) == false
    end

    test "leaves a two-way walkway two-way" do
      changeset =
        Pathway.changeset(pathway(%{pathway_mode: 1}), %{pathway_mode: 1, is_bidirectional: true})

      assert changeset.valid?
      assert get_field(changeset, :is_bidirectional) == true
    end
  end

  # mix test test/gtfs_planner/gtfs/pathway_test.exs --only describe:"editor_changeset/2 slope"
  describe "editor_changeset/2 slope" do
    test "refuses a slope entered as a percentage" do
      changeset = Pathway.editor_changeset(pathway(%{}), %{max_slope: "8.3"})

      refute changeset.valid?
      assert %{max_slope: [_message]} = Ecto.Changeset.traverse_errors(changeset, &elem(&1, 0))
    end

    test "accepts a ratio in either direction" do
      assert Pathway.editor_changeset(pathway(%{}), %{max_slope: "0.083"}).valid?
      assert Pathway.editor_changeset(pathway(%{}), %{max_slope: "-1"}).valid?
    end

    test "leaves an imported out-of-range slope alone while another field changes" do
      imported = pathway(%{max_slope: Decimal.new("8.3")})

      assert Pathway.editor_changeset(imported, %{max_slope: "8.3", min_width: "1.2"}).valid?
    end
  end

  # mix test test/gtfs_planner/gtfs/pathway_test.exs --only describe:"step_free_state/1"
  describe "step_free_state/1" do
    test "stairs and escalators are never step-free, whatever their measurements" do
      for mode <- [2, 4] do
        assert Pathway.step_free_state(pathway(%{pathway_mode: mode})) == :not_step_free

        assert Pathway.step_free_state(
                 pathway(%{pathway_mode: mode, min_width: Decimal.new("0.50")})
               ) == :not_step_free
      end
    end

    test "every other type is step-free when no measurement is recorded" do
      for mode <- [1, 3, 5, 6, 7] do
        assert Pathway.step_free_state(pathway(%{pathway_mode: mode})) == :step_free
      end
    end

    test "a ramp at the 1:12 limit passes and a steeper one is a barrier in either direction" do
      for slope <- ["0.083", "0.0833", "0.0834", "-0.0833", "0"] do
        assert Pathway.step_free_state(pathway(%{max_slope: Decimal.new(slope)})) == :step_free
      end

      for slope <- ["0.0835", "0.084", "0.1", "-0.084"] do
        ramp = pathway(%{max_slope: Decimal.new(slope)})

        assert Pathway.step_free_state(ramp) == :barrier
        assert Pathway.step_free_barriers(ramp) == [:slope]
      end
    end

    test "a 32 inch opening passes and a narrower one is a barrier" do
      for width <- ["0.81", "0.82", "1"] do
        gate = pathway(%{pathway_mode: 6, min_width: Decimal.new(width)})

        assert Pathway.step_free_state(gate) == :step_free
      end

      turnstile = pathway(%{pathway_mode: 6, min_width: Decimal.new("0.80")})

      assert Pathway.step_free_state(turnstile) == :barrier
      assert Pathway.step_free_barriers(turnstile) == [:width]
    end

    test "a zero width counts as not recorded" do
      assert Pathway.step_free_state(pathway(%{pathway_mode: 5, min_width: Decimal.new("0")})) ==
               :step_free
    end

    test "a pathway that is both steep and narrow names both barriers" do
      steep_and_narrow =
        pathway(%{max_slope: Decimal.new("0.12"), min_width: Decimal.new("0.6")})

      assert Pathway.step_free_barriers(steep_and_narrow) == [:slope, :width]
    end

    test "a type outside the specification has no state" do
      assert Pathway.step_free_state(pathway(%{pathway_mode: 9})) == nil
      assert Pathway.step_free_state(pathway(%{pathway_mode: nil})) == nil
    end
  end
end
