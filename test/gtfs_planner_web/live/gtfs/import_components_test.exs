defmodule GtfsPlannerWeb.Gtfs.ImportComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  import GtfsPlannerWeb.Gtfs.ImportComponents

  alias GtfsPlanner.Gtfs.Import.ChangeDecision
  alias GtfsPlanner.Gtfs.Import.Run

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp text(html, selector) do
    html
    |> doc()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp run(attrs) do
    struct(
      Run,
      Map.merge(
        %{id: Ecto.UUID.generate(), version_name: "October 2026 service", committed_counts: %{}},
        attrs
      )
    )
  end

  defp decision(attrs) do
    struct(
      ChangeDecision,
      Map.merge(
        %{
          decision_id: "stop:S1",
          entity_type: :stop,
          action: :modify,
          status: :pending,
          natural_key: "S1",
          changed_fields: [],
          dependency_keys: []
        },
        attrs
      )
    )
  end

  defp render_run(run, extra \\ %{}) do
    assigns = %{run: run, extra: extra}

    rendered_to_string(~H"""
    <ul>
      <.run_row
        id="row"
        run={@run}
        processing_publish={@extra[:processing_publish]}
        discardable?={Map.get(@extra, :discardable?, true)}
      />
    </ul>
    """)
  end

  defp render_decision(decision) do
    assigns = %{decision: decision}

    rendered_to_string(~H"""
    <ol><.review_row id="row" decision={@decision} /></ol>
    """)
  end

  describe "run_row/1" do
    test "a partial import lists what it saved, other files by name, and where it stopped" do
      html =
        render_run(
          run(%{
            state: "partial",
            committed_counts: %{
              "routes" => 14,
              "stops" => 386,
              "calendar_dates" => 2,
              "trips" => 0
            },
            failed_file: "stop_times.txt",
            failed_row: 48_213
          })
        )

      assert text(html, "li") =~ "Partly imported"

      assert text(html, "li") =~
               "Saved before it stopped: 14 routes, 386 stops, 2 calendar dates."

      assert text(html, "li") =~ "Last file: stop_times.txt (row 48,213)"
    end

    test "counts are shown only for a partial import" do
      html =
        render_run(
          run(%{state: "failed", committed_counts: %{"stops" => 5}, failed_file: "stops.txt"})
        )

      refute text(html, "li") =~ "Saved before it stopped"
      refute text(html, "li") =~ "Last file"
    end

    test "an interrupted import says it cannot tell how much was saved" do
      html = render_run(run(%{state: "interrupted"}))

      assert text(html, "li") =~ "we can’t tell how much was saved"
      assert text(html, "li") =~ "Interrupted"
    end

    test "only a version that finished importing offers to publish, and a busy one is disabled" do
      publishable = run(%{state: "publication_failed"})

      assert Enum.count(
               doc(render_run(publishable))
               |> LazyHTML.query("button[phx-click='publish_version']")
             ) == 1

      html = render_run(publishable, %{processing_publish: publishable.id})

      assert html
             |> doc()
             |> LazyHTML.query("button[phx-click='publish_version'][disabled]")
             |> Enum.count() ==
               1

      assert text(html, "li") =~ "Publishing…"

      assert doc(render_run(run(%{state: "failed"})))
             |> LazyHTML.query("button[phx-click='publish_version']")
             |> Enum.empty?()
    end

    test "a run that is still working offers nothing to discard" do
      html = render_run(run(%{state: "running"}), %{discardable?: false})

      assert text(html, "li") =~ "Running"
      assert doc(html) |> LazyHTML.query("button[phx-click='begin_discard']") |> Enum.empty?()
    end
  end

  describe "review_row/1" do
    test "a removal names what approving does, on the button and in the row" do
      html = render_decision(decision(%{action: :remove}))

      assert text(html, "li") =~ "Removed"
      assert text(html, "li") =~ "Approving deletes it from this version."
      assert text(html, "#row-approve") =~ "Approve removal"

      assert doc(html)
             |> LazyHTML.query("#row-approve")
             |> LazyHTML.attribute("aria-label") == ["Approve removal: Stop S1"]
    end

    test "a change that replaces someone's edits names the overwrite" do
      html = render_decision(decision(%{action: :conflict, status: :approved}))

      assert text(html, "li") =~ "Edited here"
      assert text(html, "#row-approve") =~ "Overwrite approved"

      assert doc(html) |> LazyHTML.query("#row-approve") |> LazyHTML.attribute("aria-pressed") ==
               ["true"]
    end

    test "field changes are readable without a click" do
      html =
        render_decision(
          decision(%{
            changed_fields: [
              %{"field" => "wheelchair_boarding", "before" => nil, "after" => "1"},
              %{"field" => "stop_name", "before" => "Bay 2", "after" => "Bay 2 – Routes 1 and 10"}
            ]
          })
        )

      assert text(html, "li") =~ "Changes 2 fields."
      assert text(html, "dl") =~ "Wheelchair boarding"
      assert text(html, "dl") =~ "Empty → 1"
      assert text(html, "dl") =~ "Bay 2 → Bay 2 – Routes 1 and 10"
    end

    test "a rejected change says it will not be applied" do
      html = render_decision(decision(%{action: :add, status: :rejected}))

      assert text(html, "li") =~ "This change won’t be applied."

      assert doc(html) |> LazyHTML.query("#row-reject") |> LazyHTML.attribute("aria-pressed") == [
               "true"
             ]
    end

    test "a preview row has no decisions" do
      html = render_decision(decision(%{action: :add, status: :preview}))

      assert text(html, "li") =~ "Preview only"
      assert doc(html) |> LazyHTML.query("button") |> Enum.empty?()
    end

    test "a change that was applied or went stale is labelled, not decidable" do
      for {status, word} <- [applied: "Applied", failed: "Failed", stale: "Changed since review"] do
        html = render_decision(decision(%{status: status}))

        assert text(html, "li") =~ word
        assert doc(html) |> LazyHTML.query("button") |> Enum.empty?()
      end
    end
  end

  describe "consequence/1" do
    test "is absent when nothing costly is approved" do
      assert consequence([decision(%{action: :add}), decision(%{action: :modify})]) == nil
    end

    test "names removals and replaced edits with the right number" do
      assert consequence([decision(%{action: :remove})]) == "Includes 1 removal."

      assert consequence([
               decision(%{action: :remove}),
               decision(%{action: :remove}),
               decision(%{action: :conflict})
             ]) == "Includes 2 removals and 1 change that replaces edits."

      assert consequence([decision(%{action: :conflict}), decision(%{action: :conflict})]) ==
               "Includes 2 changes that replace edits."
    end
  end

  describe "format_bytes/1" do
    test "quotes sizes in the units a file limit uses" do
      assert format_bytes(200_000_000) == "200 MB"
      assert format_bytes(18_400_000) == "18.4 MB"
      assert format_bytes(38_000) == "38 KB"
      assert format_bytes(120) == "120 B"
    end
  end

  describe "format_count/1" do
    test "groups thousands" do
      assert format_count(1_204_338) == "1,204,338"
      assert format_count(812) == "812"
    end
  end
end
