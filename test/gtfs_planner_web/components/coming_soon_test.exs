defmodule GtfsPlannerWeb.Components.ComingSoonTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  import GtfsPlannerWeb.ComingSoon, only: [coming_soon: 1]

  alias GtfsPlannerWeb.ComingSoon

  # Literal expectations transcribed from the finalized content table. They are
  # written here rather than read back from the catalog under test. Transfers,
  # Blocks, Feed details, Agencies and Fares are absent: each destination ships
  # as a working page, so it has no catalog entry.
  @catalog [
    runs: %{
      title: "Runs",
      scope: :version,
      summary: "Cut vehicle blocks into each operator’s daily work.",
      section_names: ["Duty chart", "Suggest runs", "Work rules", "Checks"]
    },
    rosters: %{
      title: "Rosters",
      scope: :version,
      summary: "Group runs into weekly lines and record which operator holds each line.",
      section_names: ["Weekly lines", "Open work", "Operators", "Crew export"]
    },
    flex: %{
      title: "Flex",
      scope: :version,
      summary:
        "Describe on-demand service on your fixed routes, such as drop-off near a stop by request.",
      section_names: ["Flex services", "Area", "Boarding", "Booking", "Export preview"]
    },
    evolutions: %{
      title: "Evolutions",
      scope: :version,
      summary:
        "Schedule pathway closures, such as elevator maintenance, and check station access while they apply.",
      section_names: ["Closures", "Access check"]
    },
    export_defaults: %{
      title: "Export defaults",
      scope: :all_versions,
      summary: "Choose how future exports are written.",
      section_names: ["ID formats", "Stop times between timepoints", "GTFS-flex files"]
    },
    feed_url: %{
      title: "Published feed URL",
      scope: :all_versions,
      summary: "Give data consumers one permanent address for your feed.",
      section_names: ["Feed URL", "What’s live", "Publishing"]
    }
  ]

  describe "feature/1" do
    test "returns the finalized copy for every fixed key" do
      assert length(@catalog) == 6

      Enum.each(@catalog, fn {key, expected} ->
        entry = ComingSoon.feature(key)

        assert entry.title == expected.title
        assert entry.scope == expected.scope
        assert entry.summary == expected.summary
        assert Enum.map(entry.sections, & &1.name) == expected.section_names
        assert Enum.all?(entry.sections, &(&1.text != ""))
      end)
    end

    test "raises for the retired alignment key" do
      assert_raise FunctionClauseError, fn ->
        ComingSoon.feature(Function.identity(:alignment))
      end
    end

    test "raises for a key outside the catalog, including the shipped Transfers key" do
      # `Function.identity/1` passes the value through while keeping it out of the
      # compiler's type checker, which would otherwise warn that the literal
      # cannot match the closed clause set. The call under test is unchanged.
      for key <- [:transfers, :feed_details, :agencies, :unbuilt] do
        assert_raise FunctionClauseError, fn ->
          ComingSoon.feature(Function.identity(key))
        end
      end
    end

    test "no longer answers for Blocks, which has a page of its own" do
      # Removing the placeholder entry is what keeps a stale `:blocks` lookup
      # from rendering placeholder copy beside the real page.
      # `Function.identity/1` hides the argument from the compiler, which would
      # otherwise warn that `feature/1` has no clause for the literal atom.
      assert_raise FunctionClauseError, fn ->
        ComingSoon.feature(Function.identity(:blocks))
      end
    end

    test "no longer answers for Fares, whose workspace shipped" do
      # The retired placeholder key must not resolve to plausible placeholder
      # copy: the Setting overview lists Fares as an Available page instead.
      assert_raise FunctionClauseError, fn ->
        ComingSoon.feature(Function.identity(:fares))
      end
    end

    test "does not convert a string into a catalog key" do
      assert_raise FunctionClauseError, fn ->
        ComingSoon.feature(Function.identity("blocks"))
      end
    end
  end

  describe "coming_soon/1" do
    test "renders the title, scope, summary and subsection count for every feature" do
      Enum.each(@catalog, fn {key, expected} ->
        doc = render_doc(ComingSoon.feature(key), "All versions")

        assert text_of(doc, "#coming-soon-title") == expected.title
        assert text_of(doc, "#coming-soon-status") == "Coming soon"
        assert text_of(doc, "#coming-soon-scope") == "All versions"
        assert text_of(doc, "#coming-soon") =~ expected.summary

        assert Enum.count(LazyHTML.query(doc, "#coming-soon-sections li")) ==
                 length(expected.section_names)
      end)
    end

    test "renders the caller's scope label verbatim" do
      doc = render_doc(ComingSoon.feature(:runs), "This version: Fall 2026")

      assert text_of(doc, "#coming-soon-scope") == "This version: Fall 2026"
    end

    test "renders exactly one title element at the requested heading level" do
      for level <- [1, 2, 3] do
        doc = render_doc(ComingSoon.feature(:runs), "All versions", level)

        assert Enum.count(LazyHTML.query(doc, "#coming-soon-title")) == 1
        assert Enum.count(LazyHTML.query(doc, "h#{level}#coming-soon-title")) == 1
        assert Enum.count(LazyHTML.query(doc, "h1, h2, h3")) == 1
      end
    end

    test "defaults to a level-one title" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.coming_soon feature={ComingSoon.feature(:flex)} scope_label="All versions" />
        """)

      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "h1#coming-soon-title")) == 1
    end

    test "renders a labelled section with a semantic subsection list and no controls" do
      doc = render_doc(ComingSoon.feature(:flex), "This version: Fall 2026")

      assert LazyHTML.attribute(LazyHTML.query(doc, "section#coming-soon"), "aria-labelledby") ==
               ["coming-soon-title"]

      assert Enum.count(LazyHTML.query(doc, "ul#coming-soon-sections")) == 1
      assert Enum.count(LazyHTML.query(doc, "#coming-soon-sections li")) == 5
      assert text_of(doc, "#coming-soon") =~ "What it will include"

      for selector <- ["form", "button", "a", "input", "select", "textarea"] do
        assert Enum.empty?(LazyHTML.query(doc, "#coming-soon #{selector}"))
      end
    end
  end

  defp render_doc(feature, scope_label, heading_level \\ 1) do
    assigns = %{feature: feature, scope_label: scope_label, heading_level: heading_level}

    ~H"""
    <.coming_soon feature={@feature} scope_label={@scope_label} heading_level={@heading_level} />
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp text_of(doc, selector) do
    doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end
end
