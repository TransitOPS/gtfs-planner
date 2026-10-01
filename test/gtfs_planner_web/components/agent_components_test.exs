defmodule GtfsPlannerWeb.AgentComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.AgentComponents

  @hostile_text "![x](https://evil.test/?d=1) <img src=x> [a](https://evil.test)"

  defp form, do: to_form(%{"message" => ""}, as: :agent)

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        id: 1,
        role: :assistant,
        text: "Both school calendars run on these five dates.",
        activity: [],
        prepared: nil,
        evidence: [],
        applied?: false,
        status: :done
      },
      overrides
    )
  end

  defp evidence(overrides \\ %{}) do
    Map.merge(
      %{
        kind: "read_result",
        title: "Weekday service",
        total: 2,
        total_label: "dates run",
        completeness: :complete,
        completeness_reason: nil,
        facts: [%{label: "Dates evaluated", value: "2"}],
        source_ref: "gtfs_calendars",
        digest: String.duplicate("a", 64),
        source_revision: nil,
        scope: %{organization_id: "org", gtfs_version_id: "version", identity: "version:version"},
        exclusions: [],
        resources: [%{kind: "calendar", id: "WEEKDAY", label: "Weekday service", link: nil}]
      },
      overrides
    )
  end

  defp prepared do
    %{
      summary: %{
        title: "Stop service",
        detail: "Mon Oct 5 – Tue Oct 6, 2026 · 2 dates",
        lines: ["Stop · School express", "Stop · School weekdays"]
      },
      command: {:date_change, [~D[2026-10-05], ~D[2026-10-06]], ["SCHOOL_EX", "SCHOOL_WD"], []}
    }
  end

  defp panel(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          id: "agent-panel",
          title: "Test helper",
          intro: "One sentence of scope.",
          examples: ["First example", "Second example"],
          scope_line: "Section · Dataset",
          status: :idle,
          entries: [],
          form: form(),
          notice: nil,
          entries_empty?: true
        },
        overrides
      )

    rendered_to_string(~H"<AgentComponents.agent_panel {assigns} />")
  end

  defp entry_html(overrides \\ %{}) do
    assigns = %{id: "agent-entry-1", entry: entry(overrides), title: "Test helper"}

    rendered_to_string(~H"<AgentComponents.agent_entry {assigns} />")
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp text(nodes), do: nodes |> LazyHTML.text() |> String.trim()

  # LazyHTML exposes its node count through the Enumerable protocol only, and
  # these assertions are about exact node counts, not list emptiness.
  defp count(nodes), do: nodes |> Enum.to_list() |> length()

  defp first_attr(nodes, attribute) do
    nodes |> LazyHTML.attribute(attribute) |> List.first()
  end

  describe "agent_panel/1" do
    test "renders the pack's own title, scope line, intro and examples" do
      panel_doc = panel() |> doc()

      assert text(LazyHTML.query(panel_doc, "#agent-panel-title")) == "Test helper"
      assert text(LazyHTML.query(panel_doc, "#agent-panel")) =~ "Section · Dataset"

      assert text(LazyHTML.query(panel_doc, "#agent-first-conversation")) =~
               "One sentence of scope."

      assert text(LazyHTML.query(panel_doc, "#agent-example-1")) == "First example"
      assert text(LazyHTML.query(panel_doc, "#agent-example-2")) == "Second example"

      other = panel(%{title: "Another helper", scope_line: "Other · Scope"}) |> doc()

      assert text(LazyHTML.query(other, "#agent-panel-title")) == "Another helper"
      assert text(LazyHTML.query(other, "#agent-panel")) =~ "Other · Scope"
      assert text(LazyHTML.query(other, "#agent-first-conversation")) =~ "Another helper"
    end

    test "names the close button after the pack's title" do
      panel_doc = panel() |> doc()

      assert first_attr(LazyHTML.query(panel_doc, "#agent-panel-close"), "aria-label") ==
               "Close Test helper"
    end

    test "carries no pack-specific copy in its source" do
      source = File.read!("lib/gtfs_planner_web/components/agent_components.ex")

      refute source =~ ~r/calendar|service[_ ]?id|SCHOOL_[A-Z]|\btrips?\b|\bgtfs version\b/i
    end

    test "offers the first-conversation state only before the conversation has an entry" do
      empty = panel() |> doc()

      assert text(LazyHTML.query(empty, "#agent-first-conversation")) =~ "What needs to change?"
      assert count(LazyHTML.query(empty, "[id^=agent-example-]")) == 2

      started =
        panel(%{
          entries: [{"agent-entry-1", entry(%{role: :user, text: "Please stop school service."})}],
          entries_empty?: false
        })
        |> doc()

      assert text(LazyHTML.query(started, "#agent-first-conversation")) == ""
      assert count(LazyHTML.query(started, "[id^=agent-example-]")) == 0
    end

    test "wires the transcript as a stream container for the panel hook" do
      panel_doc = panel() |> doc()
      entries = LazyHTML.query(panel_doc, "#agent-entries")

      assert count(entries) == 1
      assert first_attr(entries, "phx-update") == "stream"

      assert first_attr(LazyHTML.query(panel_doc, "#agent-first-conversation"), "id") ==
               "agent-first-conversation"

      # LiveView resolves the source's `.AgentPanel` to the module that declares
      # the colocated hook, so the resolved name is what the browser sees.
      assert first_attr(LazyHTML.query(panel_doc, "#agent-panel"), "phx-hook") ==
               "GtfsPlannerWeb.AgentComponents.AgentPanel"
    end

    test "shows Stop request and disables Send message while a turn runs" do
      working = panel(%{status: :working}) |> doc()

      assert text(LazyHTML.query(working, "#agent-stop")) == "Stop request"
      assert first_attr(LazyHTML.query(working, "#agent-send"), "disabled") != nil
      assert first_attr(LazyHTML.query(working, "#agent-new-conversation"), "disabled") != nil
      assert count(LazyHTML.query(working, "#agent-composer-input[disabled]")) == 0

      idle = panel() |> doc()

      assert count(LazyHTML.query(idle, "#agent-stop")) == 0
      assert first_attr(LazyHTML.query(idle, "#agent-send"), "disabled") == nil
      assert first_attr(LazyHTML.query(idle, "#agent-new-conversation"), "disabled") == nil
    end

    test "announces the ended conversation and locks the composer" do
      panel_doc = panel(%{status: :ended, entries_empty?: false}) |> doc()
      status_region = LazyHTML.query(panel_doc, "#agent-status")

      assert first_attr(status_region, "role") == "status"
      assert first_attr(status_region, "aria-live") == "polite"

      assert text(status_region) == "This conversation ended. Start a new conversation."
      assert first_attr(LazyHTML.query(panel_doc, "#agent-send"), "disabled") != nil
      assert first_attr(LazyHTML.query(panel_doc, "#agent-composer-input"), "disabled") != nil
    end

    test "announces a changed access and locks the composer" do
      panel_doc = panel(%{status: :forbidden, entries_empty?: false}) |> doc()
      status_region = LazyHTML.query(panel_doc, "#agent-status")

      assert first_attr(status_region, "role") == "status"
      assert first_attr(status_region, "aria-live") == "polite"
      assert text(status_region) == "Your access changed. The helper stopped."
      assert first_attr(LazyHTML.query(panel_doc, "#agent-send"), "disabled") != nil
      assert first_attr(LazyHTML.query(panel_doc, "#agent-composer-input"), "disabled") != nil
    end

    test "announces the exhausted conversation and locks the composer" do
      panel_doc = panel(%{status: :limit, entries_empty?: false}) |> doc()
      status_region = LazyHTML.query(panel_doc, "#agent-status")

      assert first_attr(status_region, "role") == "status"
      assert first_attr(status_region, "aria-live") == "polite"

      assert text(status_region) ==
               "This conversation reached its limit. Start a new conversation."

      assert first_attr(LazyHTML.query(panel_doc, "#agent-send"), "disabled") != nil
      assert first_attr(LazyHTML.query(panel_doc, "#agent-composer-input"), "disabled") != nil
    end

    test "announces the daily allowance and locks the composer" do
      panel_doc = panel(%{status: :allowance_exhausted, entries_empty?: false}) |> doc()
      status_region = LazyHTML.query(panel_doc, "#agent-status")

      assert first_attr(status_region, "role") == "status"
      assert first_attr(status_region, "aria-live") == "polite"
      assert text(status_region) == "Daily assistant limit reached. It resets at 00:00 UTC."
      assert first_attr(LazyHTML.query(panel_doc, "#agent-send"), "disabled") != nil
      assert first_attr(LazyHTML.query(panel_doc, "#agent-composer-input"), "disabled") != nil

      assert text(LazyHTML.query(panel_doc, "#agent-composer-hint")) ==
               "Try a new conversation after 00:00 UTC."

      entry_doc =
        entry_html(%{
          status: :allowance_exhausted,
          text: "Daily assistant limit reached. It resets at 00:00 UTC."
        })
        |> doc()

      assert text(LazyHTML.query(entry_doc, "#agent-entry-1")) =~
               "Daily assistant limit reached. It resets at 00:00 UTC."
    end

    test "shows the working status while a turn runs" do
      assert panel(%{status: :working}) |> doc() |> LazyHTML.query("#agent-status") |> text() ==
               "Working…"

      assert panel() |> doc() |> LazyHTML.query("#agent-status") |> text() == ""
    end

    test "hints at the ended and exhausted conversation next to the composer" do
      assert text(LazyHTML.query(panel(%{status: :ended}) |> doc(), "#agent-composer-hint")) ==
               "This conversation ended. Start a new conversation."

      assert text(LazyHTML.query(panel(%{status: :limit}) |> doc(), "#agent-composer-hint")) ==
               "This conversation reached its limit. Start a new conversation."

      assert text(LazyHTML.query(panel() |> doc(), "#agent-composer-hint")) ==
               "Review changes before applying."
    end

    test "bounds the composer message and submits it as the helper's own field" do
      panel_doc = panel() |> doc()
      composer = LazyHTML.query(panel_doc, "#agent-composer")
      input = LazyHTML.query(panel_doc, "#agent-composer-input")

      assert first_attr(composer, "phx-submit") == "agent_send"
      assert first_attr(input, "name") == "agent[message]"
      assert first_attr(input, "maxlength") == "2000"
      assert text(LazyHTML.query(panel_doc, "#agent-composer label")) =~ "Message Test helper"
    end

    test "shows a panel-level notice only when one is set" do
      notice = "Your edited change was saved. The original prepared change was not applied."

      notice_doc = panel(%{notice: notice}) |> doc()

      assert text(LazyHTML.query(notice_doc, "#agent-notice")) =~ notice
      assert count(LazyHTML.query(panel() |> doc(), "#agent-notice")) == 0
    end
  end

  describe "agent_entry/1" do
    test "renders text from the model literally and builds no element from it" do
      entry_doc = entry_html(%{text: @hostile_text}) |> doc()

      assert text(LazyHTML.query(entry_doc, "#agent-entry-1")) =~ @hostile_text
      assert count(LazyHTML.query(entry_doc, "#agent-entry-1 img")) == 0
      assert count(LazyHTML.query(entry_doc, "#agent-entry-1 a")) == 0
    end

    test "labels each side of the conversation and keeps the stream dom id" do
      user = entry_html(%{role: :user, text: "Please stop school service."}) |> doc()

      assert first_attr(LazyHTML.query(user, "#agent-entry-1"), "id") == "agent-entry-1"
      assert text(LazyHTML.query(user, "#agent-entry-1")) =~ "You"
      assert text(LazyHTML.query(user, "#agent-entry-1")) =~ "Please stop school service."

      assistant = entry_html() |> doc()

      assert text(LazyHTML.query(assistant, "#agent-entry-1")) =~ "Test helper"
      assert text(LazyHTML.query(assistant, "#agent-entry-1")) =~ entry().text
      assert count(LazyHTML.query(assistant, "#agent-entry-1 .badge")) == 0
    end

    test "renders the server count, facts, completeness and source above the model prose" do
      entry_doc = entry_html(%{evidence: [evidence()]}) |> doc()

      assert text(LazyHTML.query(entry_doc, "#agent-evidence-1-1")) =~ "Server result"
      assert text(LazyHTML.query(entry_doc, "#agent-evidence-1-1")) =~ "2 dates run"
      assert text(LazyHTML.query(entry_doc, "#agent-evidence-1-1")) =~ "Dates evaluated"
      assert text(LazyHTML.query(entry_doc, "#agent-evidence-1-1")) =~ "gtfs_calendars"
      assert text(LazyHTML.query(entry_doc, "#agent-evidence-1-1")) =~ "Complete"

      assert first_attr(LazyHTML.query(entry_doc, "#agent-evidence-1-1"), "data-evidence-kind") ==
               "read_result"

      # The reply under a card is marked as the model's own words.
      assert text(LazyHTML.query(entry_doc, "#agent-prose-1")) =~ "Model reply"
    end

    test "shows an incomplete answer with its reason and no invented total" do
      entry_doc =
        entry_html(%{
          evidence: [
            evidence(%{
              completeness: :incomplete,
              completeness_reason: "Some rows were left out.",
              exclusions: ["2 later dates"]
            })
          ]
        })
        |> doc()

      assert text(LazyHTML.query(entry_doc, "#agent-evidence-1-1")) =~ "Incomplete"
      assert text(LazyHTML.query(entry_doc, "#agent-evidence-1-1")) =~ "Some rows were left out."
      assert text(LazyHTML.query(entry_doc, "#agent-evidence-1-1")) =~ "Excluded · 2 later dates"
    end

    test "links only a resource the panel resolved and names the ones it did not" do
      linked =
        entry_html(%{
          evidence: [
            evidence(%{
              resources: [
                %{kind: "calendar", id: "WEEKDAY", label: "Weekday service", link: "/gtfs/v1/x"}
              ]
            })
          ]
        })
        |> doc()

      assert first_attr(LazyHTML.query(linked, "#agent-evidence-1-1 a"), "href") == "/gtfs/v1/x"

      unlinked = entry_html(%{evidence: [evidence()]}) |> doc()

      assert text(LazyHTML.query(unlinked, "#agent-evidence-1-1")) =~ "no link for this reference"
      assert count(LazyHTML.query(unlinked, "#agent-evidence-1-1 a")) == 0
    end

    test "renders no card and no prose label when the turn produced no evidence" do
      entry_doc = entry_html() |> doc()

      assert count(LazyHTML.query(entry_doc, "[data-evidence-kind]")) == 0
      assert count(LazyHTML.query(entry_doc, "#agent-prose-1 .font-bold")) == 0
    end

    test "offers the prepared change for review with its summary" do
      entry_doc = entry_html(%{prepared: prepared()}) |> doc()

      assert text(LazyHTML.query(entry_doc, "#agent-prepared-1")) =~ "Stop service"

      assert text(LazyHTML.query(entry_doc, "#agent-prepared-1")) =~
               "Mon Oct 5 – Tue Oct 6, 2026 · 2 dates"

      assert text(LazyHTML.query(entry_doc, "#agent-prepared-1")) =~ "Stop · School express"
      assert text(LazyHTML.query(entry_doc, "#agent-prepared-1")) =~ "Stop · School weekdays"
      assert text(LazyHTML.query(entry_doc, "#agent-prepared-1")) =~ "Ready to review"

      review = LazyHTML.query(entry_doc, "#agent-review-prepared-1")

      assert text(review) == "Review prepared change"
      assert first_attr(review, "phx-click") == "agent_review_prepared"
      assert first_attr(review, "phx-value-entry") == "1"
      assert first_attr(LazyHTML.query(entry_doc, "#agent-prepared-1"), "tabindex") == "-1"
    end

    test "takes the caller's own label for the prepared change it is given" do
      assigns = %{
        id: "agent-entry-1",
        entry: entry(%{prepared: prepared()}),
        title: "Test helper",
        review_label: fn %{command: {:date_change, _dates, _stop, _run}} ->
          "Review date change"
        end
      }

      entry_doc = rendered_to_string(~H"<AgentComponents.agent_entry {assigns} />") |> doc()

      assert text(LazyHTML.query(entry_doc, "#agent-review-prepared-1")) == "Review date change"
    end

    test "confirms an applied proposal on its stable card and removes the review action" do
      entry_doc = entry_html(%{prepared: prepared(), applied?: true}) |> doc()

      assert text(LazyHTML.query(entry_doc, "#agent-prepared-1")) =~ "Applied"
      assert first_attr(LazyHTML.query(entry_doc, "#agent-prepared-1"), "tabindex") == "-1"
      assert count(LazyHTML.query(entry_doc, "#agent-review-prepared-1")) == 0
    end

    test "does not mark the original proposal applied after an edited command was saved" do
      panel_doc =
        panel(%{
          notice: "Your edited change was saved. The original prepared change was not applied.",
          entries: [{"agent-entry-1", entry(%{prepared: prepared()})}],
          entries_empty?: false
        })
        |> doc()

      assert text(LazyHTML.query(panel_doc, "#agent-notice")) =~ "was not applied"
      assert count(LazyHTML.query(panel_doc, "#agent-review-prepared-1")) == 1
      assert text(LazyHTML.query(panel_doc, "#agent-prepared-1")) =~ "Ready to review"
      refute text(LazyHTML.query(panel_doc, "#agent-prepared-1")) =~ "Applied"
    end

    test "renders a stopped, incomplete or forbidden reply in a callout" do
      stopped =
        entry_html(%{status: :stopped, text: "Request stopped. No changes were saved."}) |> doc()

      stopped_callout = LazyHTML.query(stopped, "#agent-entry-1 div.border-l-4")

      assert count(stopped_callout) == 1
      assert first_attr(stopped_callout, "class") =~ "border-warning"
      assert text(stopped_callout) =~ "Request stopped. No changes were saved."

      incomplete =
        entry_html(%{
          status: :incomplete,
          text: "The helper couldn't finish this request. No changes were saved."
        })
        |> doc()

      assert first_attr(LazyHTML.query(incomplete, "#agent-entry-1 div.border-l-4"), "class") =~
               "border-warning"

      assert text(LazyHTML.query(incomplete, "#agent-entry-1")) =~
               "The helper couldn't finish this request. No changes were saved."

      forbidden =
        entry_html(%{status: :forbidden, text: "Your access changed. The helper stopped."})
        |> doc()

      assert first_attr(LazyHTML.query(forbidden, "#agent-entry-1 div.border-l-4"), "class") =~
               "border-error"

      assert text(LazyHTML.query(forbidden, "#agent-entry-1")) =~
               "Your access changed. The helper stopped."
    end

    test "offers Retry request on an unavailable reply" do
      entry_doc =
        entry_html(%{
          status: :failed,
          text:
            "The helper is unavailable right now. Try again, or make the change yourself on this page."
        })
        |> doc()

      assert first_attr(LazyHTML.query(entry_doc, "#agent-entry-1 div.border-l-4"), "class") =~
               "border-error"

      assert text(LazyHTML.query(entry_doc, "#agent-entry-1")) =~
               "The helper is unavailable right now."

      retry = LazyHTML.query(entry_doc, "#agent-retry-1")

      assert text(retry) == "Retry request"
      assert first_attr(retry, "phx-click") == "agent_retry"
      assert first_attr(retry, "phx-value-entry") == "1"
    end

    test "lists the turn's activity in a collapsed disclosure, in order" do
      entry_doc =
        entry_html(%{activity: ["Looked up calendars", "Prepared a date change"]}) |> doc()

      details = LazyHTML.query(entry_doc, "#agent-entry-1 details")

      assert count(details) == 1
      assert first_attr(details, "open") == nil
      assert text(LazyHTML.query(details, "summary")) =~ "Checked 2 steps · View activity"

      assert details |> LazyHTML.query("ol li") |> text() ==
               "Looked up calendarsPrepared a date change"

      single = entry_html(%{activity: ["Looked up calendars"]}) |> doc()

      assert text(LazyHTML.query(single, "#agent-entry-1 summary")) =~
               "Checked 1 step · View activity"

      assert count(LazyHTML.query(entry_html() |> doc(), "#agent-entry-1 details")) == 0
    end

    test "carries a working reply as a status badge without a reply body" do
      entry_doc = entry_html(%{status: :working, text: ""}) |> doc()

      assert text(LazyHTML.query(entry_doc, "#agent-entry-1")) =~ "Working"
      assert count(LazyHTML.query(entry_doc, "#agent-entry-1 p")) == 0
      assert count(LazyHTML.query(entry_doc, "#agent-entry-1 div.border-l-4")) == 0
    end
  end
end
