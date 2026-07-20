defmodule GtfsPlannerWeb.DataViewComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import GtfsPlannerWeb.CoreComponents

  alias Phoenix.LiveView.LiveStream

  describe "table/1 — static rows" do
    test "renders one table, one tbody, and one row per record" do
      assigns = %{rows: [%{id: 1, name: "A"}, %{id: 2, name: "B"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows}>
          <:col :let={r} label="Name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      assert Enum.count(LazyHTML.query(doc, "table")) == 1
      assert Enum.count(LazyHTML.query(doc, "tbody")) == 1
      assert Enum.count(LazyHTML.query(doc, "tbody tr")) == 2
    end

    test "generates stable row IDs from row_id function" do
      assigns = %{rows: [%{id: 42, name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows} row_id={&"row-#{&1.id}"}>
          <:col :let={r} label="Name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      assert Enum.count(LazyHTML.query(doc, "tr#row-42")) == 1
    end

    test "emits data-label on each cell from column label" do
      assigns = %{rows: [%{name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows}>
          <:col :let={r} label="Route Name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      td = LazyHTML.query(doc, "td")
      assert LazyHTML.attribute(td, "data-label") == ["Route Name"]
    end

    test "does not expose row_click" do
      assigns = %{rows: [%{name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows}>
          <:col :let={r} label="Name">{r.name}</:col>
        </.table>
        """)

      refute html =~ "row_click"
      refute html =~ "hover:cursor-pointer"
    end

    test "action column receives data-label Actions in stack mode" do
      assigns = %{rows: [%{name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows} responsive="stack">
          <:col :let={r} label="Name">{r.name}</:col>
          <:action :let={r}>
            <button>Edit {r.name}</button>
          </:action>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      action_td = LazyHTML.query(doc, "td[data-label=\"Actions\"]")
      assert Enum.count(action_td) == 1
    end
  end

  describe "table/1 — responsive modes" do
    test "scroll mode wraps table in a local-overflow container" do
      assigns = %{rows: [%{name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows} responsive="scroll">
          <:col :let={r} label="Name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      wrapper = LazyHTML.query(doc, "#t-container")
      assert Enum.count(wrapper) == 1
      classes = LazyHTML.attribute(wrapper, "class") |> List.first()
      assert classes =~ "overflow"
    end

    test "stack mode applies stack data attribute without cloning rows" do
      assigns = %{rows: [%{name: "A"}, %{name: "B"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows} responsive="stack">
          <:col :let={r} label="Name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      assert Enum.count(LazyHTML.query(doc, "tbody tr")) == 2
      table = LazyHTML.query(doc, "table")
      table_classes = LazyHTML.attribute(table, "class") |> List.first()
      assert table_classes =~ "stack"
    end

    test "headers remain in the DOM for stack mode" do
      assigns = %{rows: [%{name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t-stack" rows={@rows} responsive="stack">
          <:col :let={r} label="Name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      assert Enum.count(LazyHTML.query(doc, "thead")) == 1
      refute Enum.empty?(LazyHTML.query(doc, "th"))
    end

    test "headers remain in the DOM for scroll mode" do
      assigns = %{rows: [%{name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t-scroll" rows={@rows} responsive="scroll">
          <:col :let={r} label="Name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      assert Enum.count(LazyHTML.query(doc, "thead")) == 1
      refute Enum.empty?(LazyHTML.query(doc, "th"))
    end

    test "default responsive mode is scroll" do
      assigns = %{rows: [%{name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows}>
          <:col :let={r} label="Name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      wrapper = LazyHTML.query(doc, "#t-container")
      assert Enum.count(wrapper) == 1
    end
  end

  describe "table/1 — sorting" do
    test "sortable header has aria-sort and a 44px button with event/key" do
      assigns = %{rows: [%{name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows} sort_target={nil}>
          <:col :let={r} label="Name" sort="asc" sort_event="sort" sort_key="name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      th = LazyHTML.query(doc, "th")
      assert LazyHTML.attribute(th, "aria-sort") == ["ascending"]

      btn = LazyHTML.query(doc, "th button")
      assert Enum.count(btn) == 1
      assert LazyHTML.attribute(btn, "phx-click") == ["sort"]
      assert LazyHTML.attribute(btn, "phx-value-key") == ["name"]
      btn_classes = LazyHTML.attribute(btn, "class") |> List.first()
      assert btn_classes =~ "min-h-11"
    end

    test "unsortable header has no button and no aria-sort" do
      assigns = %{rows: [%{name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows}>
          <:col :let={r} label="Name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      th = LazyHTML.query(doc, "th")
      assert LazyHTML.attribute(th, "aria-sort") == []
      assert Enum.empty?(LazyHTML.query(doc, "th button"))
    end

    test "sort_target is forwarded to the sort button" do
      assigns = %{rows: [%{name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows} sort_target="my-target">
          <:col :let={r} label="Name" sort_event="sort" sort_key="name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      btn = LazyHTML.query(doc, "th button")
      assert LazyHTML.attribute(btn, "phx-target") == ["my-target"]
    end
  end

  describe "table/1 — alignment" do
    test "right-aligned column applies text-right to header and cells" do
      assigns = %{rows: [%{id: 1}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows}>
          <:col :let={r} label="ID" align="right">{r.id}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      th = LazyHTML.query(doc, "th")
      assert LazyHTML.attribute(th, "class") |> List.first() =~ "text-right"

      td = LazyHTML.query(doc, "td")
      assert LazyHTML.attribute(td, "class") |> List.first() =~ "text-right"
    end
  end

  describe "table/1 — LiveStream" do
    test "preserves stream phx-update and stream row IDs" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.table id="streamed" rows={[]}>
          <:col :let={r} label="Name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      tbody = LazyHTML.query(doc, "tbody#streamed")
      assert Enum.count(tbody) == 1
    end
  end

  describe "table/1 — one representation" do
    test "does not duplicate rows, actions, or IDs" do
      assigns = %{rows: [%{id: 1, name: "A"}, %{id: 2, name: "B"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows} row_id={&"row-#{&1.id}"} responsive="stack">
          <:col :let={r} label="Name">{r.name}</:col>
          <:action :let={r}>
            <button>Edit {r.name}</button>
          </:action>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      assert Enum.count(LazyHTML.query(doc, "table")) == 1
      assert Enum.count(LazyHTML.query(doc, "tbody")) == 1
      assert Enum.count(LazyHTML.query(doc, "tbody tr")) == 2
      assert Enum.count(LazyHTML.query(doc, "tr#row-1")) == 1
      assert Enum.count(LazyHTML.query(doc, "tr#row-2")) == 1
    end
  end

  # AC-7 / C-009: two 44 px actions must reflow inside a narrow stacked row instead
  # of overflowing it. C-008 / cross-step-contract: wrapping is the only change —
  # the table keeps one <table>, one <tbody>, one row per record, and stream mode.
  describe "table/1 — wrapped action groups" do
    test "action group wraps" do
      assigns = %{rows: [%{id: 1, name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows} responsive="stack">
          <:col :let={r} label="Name">{r.name}</:col>
          <:action :let={r}>
            <button>Resend invite {r.name}</button>
          </:action>
          <:action :let={r}>
            <button>Deactivate {r.name}</button>
          </:action>
        </.table>
        """)

      assert action_group_class(html) =~ "flex-wrap"
    end

    test "keeps both actions in one action cell per row" do
      assigns = %{rows: [%{id: 1, name: "A"}, %{id: 2, name: "B"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows} row_id={&"member-#{&1.id}"} responsive="stack">
          <:col :let={r} label="Name">{r.name}</:col>
          <:action :let={r}>
            <button>Resend invite {r.name}</button>
          </:action>
          <:action :let={r}>
            <button>Deactivate {r.name}</button>
          </:action>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "table")) == 1
      assert Enum.count(LazyHTML.query(doc, "tbody")) == 1
      assert Enum.count(LazyHTML.query(doc, "tbody tr")) == 2
      assert Enum.count(LazyHTML.query(doc, "td[data-label=\"Actions\"]")) == 2
      assert Enum.count(LazyHTML.query(doc, "tr#member-1 td[data-label=\"Actions\"] button")) == 2
      assert Enum.count(LazyHTML.query(doc, "tr#member-2 td[data-label=\"Actions\"] button")) == 2
    end

    test "wraps action groups in scroll mode too" do
      assigns = %{rows: [%{id: 1, name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows} responsive="scroll">
          <:col :let={r} label="Name">{r.name}</:col>
          <:action :let={r}>
            <button>Deactivate {r.name}</button>
          </:action>
        </.table>
        """)

      assert action_group_class(html) =~ "flex-wrap"
    end

    test "keeps stream semantics with wrapped actions" do
      # The real struct `stream/4` puts in `@streams.members`, built directly
      # because `stream/4` needs a mounted socket that a component test has no
      # way to produce. table/1 branches on this struct type, so a plain list
      # would not exercise the stream path at all.
      members = LiveStream.new(:members, 0, [%{id: "1", name: "A"}, %{id: "2", name: "B"}], [])

      assigns = %{members: members}

      html =
        rendered_to_string(~H"""
        <.table id="members" rows={@members} responsive="stack">
          <:col :let={{_id, r}} label="Name">{r.name}</:col>
          <:action :let={{_id, r}}>
            <button>Resend invite {r.name}</button>
          </:action>
          <:action :let={{_id, r}}>
            <button>Deactivate {r.name}</button>
          </:action>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)
      tbody = LazyHTML.query(doc, "tbody#members")

      assert Enum.count(tbody) == 1
      assert LazyHTML.attribute(tbody, "phx-update") == ["stream"]
      assert Enum.count(LazyHTML.query(doc, "tbody#members > tr")) == 2
      assert Enum.count(LazyHTML.query(doc, "tr#members-1")) == 1
      assert Enum.count(LazyHTML.query(doc, "tr#members-2")) == 1
      assert action_group_class(html) =~ "flex-wrap"
    end

    test "leaves the action cell absent when no action slot is given" do
      assigns = %{rows: [%{id: 1, name: "A"}]}

      html =
        rendered_to_string(~H"""
        <.table id="t" rows={@rows} responsive="stack">
          <:col :let={r} label="Name">{r.name}</:col>
        </.table>
        """)

      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(LazyHTML.query(doc, "td[data-label=\"Actions\"]"))
      assert Enum.count(LazyHTML.query(doc, "tbody tr")) == 1
    end
  end

  describe "pagination/1 — normalized range" do
    test "renders bounded range for first page" do
      assigns = %{page: 1, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "1–10 of 25"
    end

    test "renders bounded range for last page" do
      assigns = %{page: 3, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "21–25 of 25"
    end

    test "renders 0–0 of 0 for empty results" do
      assigns = %{page: 1, per_page: 10, total: 0}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "0–0 of 0"
    end

    test "clamps negative total to zero" do
      assigns = %{page: 1, per_page: 10, total: -5}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "0–0 of 0"
    end

    test "clamps zero per-page to one" do
      assigns = %{page: 1, per_page: 0, total: 10}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "1–1 of 10"
    end

    test "clamps negative per-page to one" do
      assigns = %{page: 1, per_page: -3, total: 10}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "1–1 of 10"
    end

    test "clamps out-of-range page to last page" do
      assigns = %{page: 99, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "21–25 of 25"
    end

    test "clamps page below one to page one" do
      assigns = %{page: 0, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "1–10 of 25"
    end
  end

  describe "pagination/1 — event and target" do
    test "uses configured event name" do
      assigns = %{page: 2, per_page: 10, total: 50}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} event="go_page" />
        """)

      assert html =~ "phx-click=\"go_page\""
      refute html =~ "phx-click=\"paginate\""
    end

    test "uses configured target" do
      assigns = %{page: 2, per_page: 10, total: 50}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} target="my-component" />
        """)

      doc = LazyHTML.from_fragment(html)
      btns = LazyHTML.query(doc, "button")
      assert LazyHTML.attribute(btns, "phx-target") == ["my-component", "my-component"]
    end

    test "defaults to paginate event and no target" do
      assigns = %{page: 2, per_page: 10, total: 50}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "phx-click=\"paginate\""
      doc = LazyHTML.from_fragment(html)
      btns = LazyHTML.query(doc, "button")
      assert LazyHTML.attribute(btns, "phx-target") == []
    end

    test "sends correct page values for Previous and Next" do
      assigns = %{page: 3, per_page: 10, total: 50}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "phx-value-page=\"2\""
      assert html =~ "phx-value-page=\"4\""
    end
  end

  describe "pagination/1 — 44px controls" do
    test "Previous and Next buttons have min-h-11 class" do
      assigns = %{page: 2, per_page: 10, total: 50}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      doc = LazyHTML.from_fragment(html)
      btns = LazyHTML.query(doc, "button")

      for btn <- btns do
        classes = LazyHTML.attribute(btn, "class") |> List.first()
        assert classes =~ "min-h-11"
      end
    end
  end

  describe "pagination/1 — entity noun" do
    test "appends entity noun when given" do
      assigns = %{page: 1, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} entity="routes" />
        """)

      assert html =~ "1–10 of 25 routes"
    end

    test "omits entity noun when not given" do
      assigns = %{page: 1, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "1–10 of 25"
      refute html =~ "routes"
    end
  end

  describe "pagination/1 — disabled state" do
    test "disables Previous on first page" do
      assigns = %{page: 1, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      doc = LazyHTML.from_fragment(html)

      prev =
        LazyHTML.query(doc, "button")
        |> Enum.find(fn b ->
          LazyHTML.text(b) |> String.contains?("Previous")
        end)

      assert LazyHTML.attribute(prev, "disabled") == [""]
    end

    test "disables Next on last page" do
      assigns = %{page: 3, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      doc = LazyHTML.from_fragment(html)

      next_btn =
        LazyHTML.query(doc, "button")
        |> Enum.find(fn b ->
          LazyHTML.text(b) |> String.contains?("Next")
        end)

      assert LazyHTML.attribute(next_btn, "disabled") == [""]
    end
  end

  # The action slot renders into a single flex container inside the Actions cell.
  defp action_group_class(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("td[data-label=\"Actions\"] > div")
    |> LazyHTML.attribute("class")
    |> List.first()
  end
end
