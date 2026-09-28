defmodule GtfsPlannerWeb.Gtfs.RouteFormComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlannerWeb.Gtfs.RouteFormComponents

  @organization_id "10000000-0000-0000-0000-000000000001"
  @gtfs_version_id "20000000-0000-0000-0000-000000000001"

  # `mode_counts` reaches the component already ordered by descending count then
  # ascending mode (`Routes.route_editor/3`), and the agency options are the
  # same scoped projection.
  @mode_counts [
    %{route_type: 3, count: 12},
    %{route_type: 2, count: 4},
    %{route_type: 0, count: 1}
  ]

  @agencies [
    %{agency_id: "NCT", agency_name: "North City Transit", agency_url: "https://nct.example"},
    %{agency_id: "CTR", agency_name: "Central Rail", agency_url: nil}
  ]

  defp new_route do
    %Route{
      organization_id: @organization_id,
      gtfs_version_id: @gtfs_version_id,
      route_id: "B15",
      route_color: "FFFFFF",
      route_text_color: "000000"
    }
  end

  defp create_form(attrs \\ %{}) do
    new_route()
    |> Route.editor_changeset(Map.merge(%{"route_id" => "B15"}, attrs), :create)
    |> to_form(as: :route)
  end

  defp details_form(attrs \\ %{}) do
    new_route()
    |> Map.merge(%{id: "30000000-0000-0000-0000-000000000001", agency_id: "NCT"})
    |> Route.editor_changeset(attrs, :edit)
    |> to_form(as: :route)
  end

  # The form a rejected save leaves behind: the same changeset with the
  # create action, which is what carries the field errors into the form.
  defp rejected_create_form do
    new_route()
    |> Route.editor_changeset(
      %{"route_id" => "B15", "route_short_name" => "", "route_long_name" => ""},
      :create
    )
    |> to_form(as: :route, action: :insert)
  end

  # The form a rejected save leaves behind when only the mode is missing, which
  # is the one failure the shared mode group has to announce itself.
  defp rejected_mode_form do
    new_route()
    |> Route.editor_changeset(
      %{"route_id" => "B15", "route_short_name" => "15", "route_type" => ""},
      :create
    )
    |> to_form(as: :route, action: :insert)
  end

  # The form a rejected save leaves behind when the command's scoped-agency
  # recheck under seam `S-1` rejected the submitted agency. That check is the
  # command's, not the changeset's, so the test adds the error the way the
  # command will and the component's job is to show it.
  defp rejected_agency_form do
    new_route()
    |> Route.editor_changeset(
      %{"route_id" => "B15", "route_short_name" => "15", "route_type" => 3, "agency_id" => "ZZ"},
      :create
    )
    |> Ecto.Changeset.add_error(:agency_id, "is not an agency in this version")
    |> to_form(as: :route, action: :insert)
  end

  defp identity(form, opts \\ []) do
    assigns =
      Keyword.merge(
        [form: form, prefix: "new-route", mode_counts: @mode_counts, agency_options: @agencies],
        opts
      )

    render_component(&RouteFormComponents.identity_fields/1, assigns)
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  # `LazyHTML.query/2` returns a multi-node document, so the assertions read the
  # attribute list of the matched nodes instead of counting them.
  defp attrs(d, selector, name) when is_binary(selector) and is_binary(name) do
    d |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp ids(d, selector \\ "[id]"), do: attrs(d, selector, "id")

  defp text(d, selector), do: d |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  # Document-order position of the first node carrying a given id, so the
  # shared-name submission order is asserted rather than assumed.
  defp index_of(d, id) do
    html = d |> LazyHTML.to_html() |> IO.iodata_to_binary()

    [before, _] = String.split(html, ~r/<[^>]*\bid="#{id}"/, parts: 2)
    length(String.split(before, "<"))
  end

  describe "identity_fields/1 names" do
    test "both name inputs are individually optional and carry stable prefix ids" do
      d = doc(identity(create_form(%{"route_short_name" => "15"})))

      assert ids(d, "#new-route-short") == ["new-route-short"]
      assert ids(d, "#new-route-long") == ["new-route-long"]
      assert attrs(d, "label[for='new-route-short']", "for") == ["new-route-short"]
      assert attrs(d, "label[for='new-route-long']", "for") == ["new-route-long"]
      assert text(d, "label[for='new-route-short']") == "Route number"
      assert text(d, "label[for='new-route-long']") == "Route name"

      # R1 accepts either name, so neither control is browser-required; the
      # "at least one name" rule belongs to the changeset.
      assert attrs(d, "#new-route-short", "required") == []
      assert attrs(d, "#new-route-long", "required") == []
      assert attrs(d, "#new-route-short", "name") == ["route[route_short_name]"]
      assert attrs(d, "#new-route-long", "name") == ["route[route_long_name]"]
      assert attrs(d, "#new-route-short", "value") == ["15"]
      assert ids(d) == Enum.uniq(ids(d))
    end

    test "both name inputs validate on blur for the shared at-least-one-name rule" do
      d = doc(identity(rejected_create_form()))

      assert attrs(d, "#new-route-short", "phx-debounce") == ["blur"]
      assert attrs(d, "#new-route-long", "phx-debounce") == ["blur"]
      assert attrs(d, "#new-route-short", "aria-invalid") == ["true"]
      assert attrs(d, "#new-route-long", "aria-invalid") == ["true"]

      # R1's rule is about the pair, so it is announced once and both controls
      # point at it rather than the message repeating inside the 132px column.
      assert attrs(d, "#new-route-short", "aria-describedby") == ["new-route-names-error"]
      assert attrs(d, "#new-route-long", "aria-describedby") == ["new-route-names-error"]
      assert ids(d, "#new-route-names-error") == ["new-route-names-error"]

      assert text(d, "#new-route-names-error") =~
               "at least one of route_short_name or route_long_name must be present"

      assert ids(d, "#new-route-short-error") == []
    end

    test "every accepted mode is reachable and the chips are one keyboard radio group" do
      d = doc(identity(create_form()))
      group = text(d, "#new-route-mode-group")

      # The three modes this version uses most are one-click radio chips inside
      # one fieldset, so arrow keys and the legend name the whole group.
      assert ids(d, "#new-route-mode-group") == ["new-route-mode-group"]
      assert text(d, "#new-route-mode-group legend") == "Mode"

      assert ids(d, "#new-route-mode-group input[type='radio']") == [
               "new-route-mode-3",
               "new-route-mode-2",
               "new-route-mode-0"
             ]

      assert attrs(d, "#new-route-mode-group input[type='radio']", "name") == [
               "route[route_type]",
               "route[route_type]",
               "route[route_type]"
             ]

      assert attrs(d, "#new-route-mode-group input[type='radio']", "value") == ["3", "2", "0"]

      for mode <- [3, 2, 0] do
        assert group =~ Route.route_type_label(mode)
      end

      assert group =~ "Modes already used in this version come first."

      # The select carries every accepted mode the chips leave out, so the union
      # is the complete accepted set the changeset validates against.
      other = attrs(d, "#new-route-mode-other option", "value") |> Enum.reject(&(&1 == ""))
      accepted = Enum.map(Route.route_type_options(), fn {_label, value} -> to_string(value) end)

      assert Enum.sort(other) == Enum.sort(accepted -- ["3", "2", "0"])
      assert attrs(d, "#new-route-mode-other", "name") == ["route[route_type]"]
      assert attrs(d, "label[for='new-route-mode-other']", "for") == ["new-route-mode-other"]
      assert text(d, "label[for='new-route-mode-other']") == "Other mode"

      # The select is written first in the DOM and ordered last visually, so a
      # checked chip is the last successful control for the shared name and
      # always wins; an "Other mode…" value wins because no chip is checked.
      assert index_of(d, "new-route-mode-other") < index_of(d, "new-route-mode-3")
    end

    test "a chip selection clears the other-mode select so the chip's value submits" do
      chip_selected = doc(identity(create_form(%{"route_type" => "3"})))

      assert ids(chip_selected, "input[type='radio'][checked]") == ["new-route-mode-3"]

      # The prompt option is the select's default, so a chip choice leaves no
      # explicitly selected option and the select contributes nothing.
      assert ids(chip_selected, "#new-route-mode-other option[selected]") == []
      assert hd(attrs(chip_selected, "#new-route-mode-other option", "value")) == ""
      assert text(chip_selected, "#new-route-mode-other option:first-child") == "Other mode…"
    end

    test "a mode the version never used is still reachable and reads as chosen" do
      other_selected = doc(identity(create_form(%{"route_type" => "4"})))

      assert ids(other_selected, "input[type='radio'][checked]") == []
      assert attrs(other_selected, "#new-route-mode-other option[selected]", "value") == ["4"]
      assert text(other_selected, "#new-route-mode-other option[selected]") == "Ferry"
    end

    test "a rejected mode is announced from the select that carries the field" do
      d = doc(identity(rejected_mode_form()))

      assert attrs(d, "#new-route-mode-other", "aria-invalid") == ["true"]
      assert attrs(d, "#new-route-mode-other", "aria-describedby") == ["new-route-mode-error"]
      assert text(d, "#new-route-mode-error") == "can't be blank"
    end
  end

  describe "identity_fields/1 agency presentations" do
    test "a version without an agency states it and offers no control" do
      d = doc(identity(create_form(), agency_options: []))

      assert text(d, "#new-route-agency-label") == "Agency"
      assert ids(d, "#new-route-agency-readonly") == []
      assert ids(d, "#new-route-agency") == []
      assert text(d, "#new-route-identity") =~ "no agency yet"
    end

    test "a version with one agency is read-only and submits that agency" do
      d = doc(identity(details_form(), agency_options: [hd(@agencies)]))

      assert text(d, "#new-route-agency-name") == "North City Transit"
      assert text(d, "#new-route-agency-label") == "Agency"
      assert attrs(d, "#new-route-agency", "type") == ["hidden"]
      assert attrs(d, "#new-route-agency", "name") == ["route[agency_id]"]
      assert attrs(d, "#new-route-agency", "value") == ["NCT"]
      assert text(d, "#new-route-agency-readonly") =~ "The only agency in this version"
    end

    test "a many-agency version announces a rejected agency instead of saving it" do
      d = doc(identity(rejected_agency_form()))

      assert attrs(d, "#new-route-agency", "aria-invalid") == ["true"]

      assert attrs(d, "#new-route-agency", "aria-describedby") == [
               "new-route-agency-error new-route-agency-help"
             ]

      assert text(d, "#new-route-agency-error") ==
               "is not an agency in this version"
    end

    test "an unassigned route in a one-agency version says the save will assign it" do
      d = doc(identity(create_form(), agency_options: [hd(@agencies)]))

      assert text(d, "#new-route-agency-readonly") =~ "Saving assigns it to this route"
    end

    test "a version with many agencies is a labelled select over every option" do
      d = doc(identity(create_form(), agency_options: @agencies))

      assert text(d, "label[for='new-route-agency']") == "Agency"
      assert attrs(d, "#new-route-agency", "name") == ["route[agency_id]"]
      assert attrs(d, "#new-route-agency option", "value") == ["", "NCT", "CTR"]
      assert text(d, "#new-route-agency") =~ "North City Transit"
      assert text(d, "#new-route-agency") =~ "Central Rail"
      assert attrs(d, "#new-route-agency", "aria-describedby") == ["new-route-agency-help"]
      assert text(d, "#new-route-agency-help") == "Required: this version has 2 agencies."
    end
  end

  describe "identity_fields/1 shared use by the create drawer and Details" do
    test "a create form and a details form render together without duplicate ids" do
      create = doc(identity(create_form(%{"route_type" => "3"}), prefix: "new-route"))
      details = doc(identity(details_form(%{"route_type" => 2}), prefix: "route-details"))

      assert ids(create) == Enum.uniq(ids(create))
      assert ids(details) == Enum.uniq(ids(details))
      assert Enum.filter(ids(create), &(&1 in ids(details))) == []

      assert ids(details, "#route-details-short") == ["route-details-short"]
      assert text(details, "label[for='route-details-long']") == "Route name"
      assert ids(details, "input[type='radio'][checked]") == ["route-details-mode-2"]
      assert text(details, "#route-details-mode-other") =~ "Other mode…"
      assert text(details, "label[for='route-details-agency']") == "Agency"
    end
  end
end
