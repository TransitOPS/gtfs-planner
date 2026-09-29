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

  defp colors(form, opts \\ []) do
    assigns =
      Keyword.merge([form: form, prefix: "new-route"], opts)

    render_component(&RouteFormComponents.color_fields/1, assigns)
  end

  # The form a rejected save leaves behind when the submitted colors are not
  # hex, which is the failure the shared color field has to announce.
  defp rejected_color_form do
    new_route()
    |> Route.editor_changeset(
      %{
        "route_id" => "B15",
        "route_short_name" => "15",
        "route_type" => 3,
        "route_color" => "6A1B9"
      },
      :create
    )
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
               "Enter a route number, a route name, or both."

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
      assert text(d, "#new-route-mode-error") == "Choose a mode."
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

  describe "color_fields/1 submitted values" do
    test "only the hex fields submit a color and the picker stays local" do
      d = doc(colors(create_form(%{"route_color" => "5BC5F2"})))

      # R7: the picker is a local editing affordance, so the one
      # `route[route_color]` value that reaches the server is the hex field.
      assert attrs(d, "#new-route-color-picker", "type") == ["color"]
      assert attrs(d, "#new-route-color-picker", "name") == []
      assert attrs(d, "#new-route-color-picker", "value") == ["#5BC5F2"]
      assert attrs(d, "#new-route-color", "name") == ["route[route_color]"]
      assert attrs(d, "#new-route-color", "value") == ["5BC5F2"]
      assert attrs(d, "#new-route-color", "phx-debounce") == ["blur"]

      # `text_mode` is transient transport metadata (R1), so it is not a
      # `route[...]` schema field the changeset would have to strip later.
      assert attrs(d, "input[name='text_mode']", "name") == ["text_mode", "text_mode"]
      assert attrs(d, "input[name='text_mode']", "value") == ["automatic", "custom"]
      assert attrs(d, "#new-route-text", "name") == ["route[route_text_color]"]
    end

    test "an imported custom text color stays custom and keeps its own value" do
      # Black on 0F4C81 is not the automatic pick (white is, at 8.4:1), so
      # R1/AC-3 preserve the imported custom value as Custom and an unrelated
      # edit cannot silently convert it to the automatic one.
      d =
        doc(colors(details_form(%{"route_color" => "0F4C81", "route_text_color" => "000000"})))

      assert ids(d, "input[type='radio'][checked]") == ["new-route-text-mode-custom"]
      assert attrs(d, "#new-route-text", "value") == ["000000"]
      assert ids(d, "#new-route-text-wrap.hidden") == []
    end

    test "a text color that already is the automatic pick renders as automatic" do
      d =
        doc(colors(details_form(%{"route_color" => "0F4C81", "route_text_color" => "FFFFFF"})))

      assert ids(d, "input[type='radio'][checked]") == ["new-route-text-mode-automatic"]
      assert ids(d, "#new-route-text-wrap.hidden") == ["new-route-text-wrap"]
    end

    test "a blank draft previews the R1 defaults: white fill, black text" do
      d = doc(colors(create_form()))

      assert attrs(d, "#new-route-color-picker", "value") == ["#FFFFFF"]
      assert ids(d, "input[type='radio'][checked]") == ["new-route-text-mode-automatic"]
      assert text(d, "#new-route-contrast-ratio") == "21.0:1 contrast"
      assert text(d, "#new-route-contrast-verdict-text") == "Easy to read"
    end

    test "an explicit draft mode wins over the derived one in both directions" do
      # Black text on 0F4C81 derives as Custom; the draft says Automatic.
      automatic =
        doc(
          colors(
            details_form(%{"route_color" => "0F4C81", "route_text_color" => "000000"}),
            text_mode: "automatic"
          )
        )

      assert ids(automatic, "input[type='radio'][checked]") == ["new-route-text-mode-automatic"]
      assert ids(automatic, "#new-route-text-wrap.hidden") == ["new-route-text-wrap"]

      # White text on 0F4C81 derives as Automatic; the draft says Custom, which
      # is the mode the create drawer opens with.
      custom =
        doc(
          colors(
            details_form(%{"route_color" => "0F4C81", "route_text_color" => "FFFFFF"}),
            text_mode: "custom"
          )
        )

      assert ids(custom, "input[type='radio'][checked]") == ["new-route-text-mode-custom"]
      assert ids(custom, "#new-route-text-wrap.hidden") == []

      # Switching away from Custom never rewrites the operator's own hex, so
      # switching back is lossless.
      assert attrs(custom, "#new-route-text", "value") == ["FFFFFF"]
    end
  end

  describe "color_fields/1 contrast readout" do
    test "a custom text color below 4.5:1 is advisory, saveable and offers the fix" do
      # The reference's create-contrast fixture: 5BC5F2 with white text.
      d =
        doc(
          colors(
            create_form(%{"route_color" => "5BC5F2", "route_text_color" => "FFFFFF"}),
            text_mode: "custom"
          )
        )

      assert text(d, "#new-route-contrast") =~ "Hard to read"
      assert text(d, "#new-route-contrast-ratio") == "2.0:1 contrast, below 4.5:1"

      assert text(d, "#new-route-contrast-advice") =~
               "The app shows this badge with black text; exports keep what you enter."

      # Warnings never block a save: nothing is disabled or readonly.
      assert attrs(d, "#new-route-color", "disabled") == []
      assert attrs(d, "#new-route-text", "disabled") == []
      assert attrs(d, "#new-route-text", "readonly") == []
      assert ids(d, "button:disabled") == []

      changeset =
        Route.editor_changeset(
          %Route{route_color: "5BC5F2", route_text_color: "FFFFFF"},
          %{"route_color" => "5BC5F2", "route_text_color" => "FFFFFF", "text_mode" => "custom"},
          :edit
        )

      refute Enum.any?(changeset.errors, fn {field, _} ->
               field in [:route_color, :route_text_color]
             end)
    end

    test "the automatic fix is a real focusable button that is always rendered" do
      hard =
        doc(
          colors(
            create_form(%{"route_color" => "5BC5F2", "route_text_color" => "FFFFFF"}),
            text_mode: "custom"
          )
        )

      easy = doc(colors(create_form(%{"route_color" => "5BC5F2"})))
      fix = "new-route-use-automatic"

      # Present in both states so a LiveView update cannot remove the control an
      # operator is standing on; only its container is shown or hidden.
      assert ids(hard, "##{fix}") == [fix]
      assert ids(easy, "##{fix}") == [fix]
      assert text(hard, "##{fix}") == "Use automatic text color"
      assert ids(hard, "#new-route-contrast-advice.hidden") == []
      assert ids(easy, "#new-route-contrast-advice.hidden") == ["new-route-contrast-advice"]
      assert attrs(hard, "##{fix}", "type") == ["button"]
      assert attrs(hard, "##{fix}", "tabindex") == []
    end

    test "an unreadable draft states no verdict instead of claiming a ratio" do
      d = doc(colors(create_form(%{"route_color" => "6A1B9"}), text_mode: "custom"))

      assert text(d, "#new-route-contrast-ratio") == "–:1 contrast"
      assert ids(d, "#new-route-contrast-verdict.hidden") == ["new-route-contrast-verdict"]
      assert ids(d, "#new-route-contrast-advice.hidden") == ["new-route-contrast-advice"]

      # An unvalidated value never reaches an inline style (RouteIdentity).
      assert attrs(d, "#new-route-contrast-badge span", "style") == []
    end

    test "the preview badge is the application badge for the draft colors" do
      d = doc(colors(create_form(%{"route_short_name" => "33", "route_color" => "6A1B9A"})))

      assert text(d, "#new-route-contrast-badge") == "33"

      assert attrs(d, "#new-route-contrast-badge span", "style") == [
               "background-color: #6A1B9A; color: #FFFFFF"
             ]
    end
  end

  describe "color_fields/1 shared use and errors" do
    test "a rejected color is announced from the field that carries it" do
      d = doc(colors(rejected_color_form()))

      assert attrs(d, "#new-route-color", "aria-invalid") == ["true"]

      assert attrs(d, "#new-route-color", "aria-describedby") == [
               "new-route-color-error new-route-color-help"
             ]

      assert text(d, "#new-route-color-error") =~ "Enter six hex digits for the route color"
      assert attrs(d, "#new-route-text", "aria-invalid") == ["false"]
    end

    test "the create drawer and Details forms can both render it without id collisions" do
      create = doc(colors(create_form(%{"route_color" => "5BC5F2"}), prefix: "new-route"))
      details = doc(colors(details_form(%{"route_color" => "0F4C81"}), prefix: "route-details"))

      assert ids(create) == Enum.uniq(ids(create))
      assert ids(details) == Enum.uniq(ids(details))
      assert Enum.filter(ids(create), &(&1 in ids(details))) == []

      assert ids(details, "#route-details-color-picker") == ["route-details-color-picker"]
      assert attrs(details, "#route-details-color-picker", "value") == ["#0F4C81"]
      assert text(details, "label[for='route-details-color']") =~ "Route color"
      assert text(details, "#route-details-color-help") =~ "blank means white"
    end
  end

  describe "advisory field warnings computation" do
    # `field_warnings/1` is the one pure function both mounting surfaces call,
    # so the prototype's rules are asserted here once: trim/case-fold
    # duplicates over 12 code points, CIE76 similarity over nonwhite colors,
    # exact normalized agency-home URLs, boarding against known-missing paths,
    # and the changed-field gate that keeps untouched imported values quiet.
    @candidates [
      %{id: "uuid-a", route_id: "E1", route_short_name: "14", route_color: "2060C2"},
      %{id: "uuid-b", route_id: "W1", route_short_name: " White ", route_color: "FFFFFF"},
      %{id: "uuid-c", route_id: "N0", route_short_name: nil, route_color: nil}
    ]

    @agencies [
      %{agency_id: "NCT", agency_name: "North City Transit", agency_url: "https://nct.example"}
    ]

    test "creation evaluates every new value with no UUID excluded" do
      warnings =
        RouteFormComponents.field_warnings(%{
          draft: %{route_short_name: "  14  ", route_color: "2060c3", route_url: nil},
          changed: :all,
          current_uuid: nil,
          candidates: @candidates,
          agencies: @agencies
        })

      assert warnings.short == %{kind: :duplicate, route: Enum.at(@candidates, 0)}
      assert warnings.similar.route.route_id == "E1"
      assert warnings.url == nil
      assert warnings.boarding == nil
    end

    test "the current UUID is excluded from the saved candidates" do
      warnings =
        RouteFormComponents.field_warnings(%{
          draft: %{route_short_name: "14", route_color: "2060C2"},
          changed: :all,
          current_uuid: "uuid-a",
          candidates: @candidates,
          agencies: @agencies
        })

      # The draft matching its own saved row is not a collision.
      assert warnings.short == nil
      assert warnings.similar == nil
    end

    test "a number over 12 code points warns only when it is not a duplicate" do
      long_number = "1234567890123"

      plain =
        RouteFormComponents.field_warnings(%{
          draft: %{route_short_name: long_number},
          changed: :all,
          candidates: @candidates
        })

      assert plain.short == %{kind: :too_long}

      # Duplicate takes precedence: a trimmed, case-folded match is the more
      # concrete confusion, whatever its length.
      duplicated =
        RouteFormComponents.field_warnings(%{
          draft: %{route_short_name: long_number},
          changed: :all,
          candidates: [%{id: "uuid-d", route_id: "L1", route_short_name: long_number}]
        })

      assert duplicated.short.kind == :duplicate
      assert duplicated.short.route.route_id == "L1"
    end

    test "similarity compares valid nonwhite colors and names the nearest" do
      warnings =
        RouteFormComponents.field_warnings(%{
          draft: %{route_color: "D32F2F"},
          changed: :all,
          candidates: [
            %{id: "uuid-e", route_id: "FAR", route_short_name: "1", route_color: "1A73E8"},
            %{id: "uuid-f", route_id: "NEAR", route_short_name: "2", route_color: "c0392b"}
          ]
        })

      assert warnings.similar.route.route_id == "NEAR"

      # An unusable draft color is the changeset's error, not a warning.
      invalid =
        RouteFormComponents.field_warnings(%{
          draft: %{route_color: "6A1B9"},
          changed: :all,
          candidates: @candidates
        })

      assert invalid.similar == nil
    end

    test "the agency home URL compares normalized and falls back to a lone agency" do
      exact =
        RouteFormComponents.field_warnings(%{
          draft: %{route_url: "HTTPS://NCT.Example/"},
          changed: :all,
          agencies: @agencies
        })

      assert exact.url.agency.agency_name == "North City Transit"

      deeper =
        RouteFormComponents.field_warnings(%{
          draft: %{route_url: "https://nct.example/routes/14"},
          changed: :all,
          agencies: @agencies
        })

      assert deeper.url == nil

      # With no agency selected, the version's only agency is the comparison.
      unassigned =
        RouteFormComponents.field_warnings(%{
          draft: %{route_url: "https://nct.example", agency_id: nil},
          changed: :all,
          agencies: @agencies
        })

      assert unassigned.url != nil

      many =
        RouteFormComponents.field_warnings(%{
          draft: %{route_url: "https://nct.example", agency_id: nil},
          changed: :all,
          agencies:
            Enum.concat(@agencies, [%{agency_id: "CTR", agency_name: "C", agency_url: nil}])
        })

      assert many.url == nil
    end

    test "boarding warns from known missing paths and never from unknown geometry" do
      enabled = %{continuous_pickup: 0, continuous_drop_off: 1}

      missing =
        RouteFormComponents.field_warnings(%{
          draft: enabled,
          changed: :all,
          geometry: %{patterns_missing: 2}
        })

      assert missing.boarding == %{patterns_missing: 2}

      # Boarding that is off everywhere has no advisory to earn.
      disabled =
        RouteFormComponents.field_warnings(%{
          draft: %{continuous_pickup: 1, continuous_drop_off: 1},
          changed: :all,
          geometry: %{patterns_missing: 2}
        })

      assert disabled.boarding == nil

      # A failed map read is unknown geometry: no path is fabricated as missing.
      unavailable =
        RouteFormComponents.field_warnings(%{
          draft: enabled,
          changed: :all,
          geometry: :unavailable
        })

      assert unavailable.boarding == nil
    end

    test "Details warns only about changed relevant fields" do
      draft = %{
        route_short_name: "14",
        route_color: "2060C2",
        route_url: "https://nct.example",
        continuous_pickup: 0
      }

      quiet =
        RouteFormComponents.field_warnings(%{
          draft: draft,
          changed: [:route_desc],
          current_uuid: "uuid-z",
          candidates: @candidates,
          agencies: @agencies,
          geometry: %{patterns_missing: 3}
        })

      assert quiet == %{short: nil, similar: nil, url: nil, boarding: nil}

      # The one field that changed earns exactly its own advisory.
      color_changed =
        RouteFormComponents.field_warnings(%{
          draft: draft,
          changed: [:route_color],
          current_uuid: "uuid-z",
          candidates: @candidates,
          agencies: @agencies,
          geometry: %{patterns_missing: 3}
        })

      assert color_changed.similar.route.route_id == "E1"
      assert color_changed.short == nil
      assert color_changed.url == nil
      assert color_changed.boarding == nil
    end
  end

  describe "advisory field warning rendering" do
    test "the number advisory renders under the name fields and is announced" do
      d =
        doc(
          identity(create_form(%{"route_short_name" => "14"}),
            short_warning: %{kind: :duplicate, route: %{route_id: "E1", route_short_name: "14"}}
          )
        )

      assert ids(d, "#new-route-short-warn") == ["new-route-short-warn"]
      assert text(d, "#new-route-short-warn") =~ "Route E1"
      assert text(d, "#new-route-short-warn") =~ "already uses the number “14”"
      assert text(d, "#new-route-short-warn") =~ "You can still save."
      assert attrs(d, "#new-route-short", "aria-describedby") == ["new-route-short-warn"]
    end

    test "a clean draft renders no warning boxes and names no advisory" do
      d = doc(identity(create_form(%{"route_short_name" => "15"})))

      assert ids(d, "#new-route-short-warn") == []

      refute Enum.any?(
               attrs(d, "#new-route-short", "aria-describedby"),
               &String.contains?(&1, "warn")
             )
    end
  end
end
