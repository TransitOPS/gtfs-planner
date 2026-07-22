defmodule GtfsPlannerWeb.Components.DiagramPaletteTest do
  use ExUnit.Case, async: true

  alias GtfsPlannerWeb.Components.DiagramPalette

  @required_roles ~w(
    active_stop fallback_stop other_level_stop
    pathway_forward pathway_reverse pathway_inactive
    label label_halo ruler focus selection building_outline error degraded
    journal_open
  )a

  test "defines every named diagram role with a semantic CSS variable and non-color cue" do
    assert Map.keys(DiagramPalette.roles()) |> Enum.sort() == Enum.sort(@required_roles)

    assert DiagramPalette.roles().journal_open == %{
             css_variable: "--diagram-journal-open",
             color: "#B45309",
             cue: "left accent, target label, and text state"
           }

    for role <- @required_roles do
      metadata = DiagramPalette.roles() |> Map.fetch!(role)

      assert metadata.css_variable =~ "--diagram-"
      assert metadata.color =~ ~r/\A#[0-9A-F]{6}\z/
      assert is_binary(metadata.cue) and metadata.cue != ""
    end
  end

  test "serializes CSS variables in a stable role order" do
    declarations = DiagramPalette.css_custom_properties()

    assert declarations == DiagramPalette.css_custom_properties()
    assert declarations =~ "--diagram-active-stop: #0B5FFF"
    assert declarations =~ "--diagram-label-halo: #FFFFFF"
    assert declarations =~ "--diagram-degraded: #6B7280"
    assert declarations =~ "--diagram-journal-open: #B45309"

    variables = DiagramPalette.css_variables()
    assert Enum.map(variables, &elem(&1, 0)) == Enum.sort(Enum.map(variables, &elem(&1, 0)))
  end

  test "fixed label and halo fixtures meet the documented contrast floor" do
    assert DiagramPalette.contrast_ratio("#1F2937", "#FFFFFF") >= 4.5
    assert DiagramPalette.contrast_ratio("#FFFFFF", "#1F2937") >= 4.5
  end
end
