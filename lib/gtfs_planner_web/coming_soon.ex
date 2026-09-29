defmodule GtfsPlannerWeb.ComingSoon do
  @moduledoc """
  Shared content and body for destinations that are navigable before they are built.

  Every placeholder surface renders one `coming_soon/1` instance from this fixed
  catalog, so a title, summary, scope and outcome list stay in one place instead
  of being restated per consumer. The caller owns the page shell: it supplies the
  heading level its surrounding page needs and the scope label it can resolve at
  runtime.

  `feature/1` answers for the four catalog keys only. Any other key raises, so a
  typo or an unmapped user string cannot render plausible-looking placeholder copy
  for a feature nobody has described.
  """

  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [scope_line: 1]

  @type scope :: :version | :all_versions

  @type feature :: %{
          title: String.t(),
          summary: String.t(),
          scope: scope(),
          sections: [%{name: String.t(), text: String.t()}]
        }

  @doc """
  Returns the fixed catalog entry for one unbuilt destination.

  Keys, titles, summaries and scopes come from the finalized content table in
  the information-architecture spec. Each `sections` entry names one thing the
  feature will let a person do, in the words an operator uses, followed by one
  sentence that says what it covers and where it stops.
  """
  @spec feature(atom()) :: feature()
  def feature(:runs) do
    %{
      title: "Runs",
      scope: :version,
      summary: "Cut vehicle blocks into each operator’s daily work.",
      sections: [
        %{
          name: "Review every run on one chart",
          text:
            "See when each operator signs on, which blocks they drive, where the break falls and when they sign off."
        },
        %{
          name: "Get suggested runs",
          text: "Preview a suggested way to cut your blocks. Nothing changes until you apply it."
        },
        %{
          name: "Set your work rules",
          text:
            "Enter report time, sign-off time, the longest paid break and the longest spread. Runs shows how paid time adds up."
        },
        %{
          name: "Catch problems early",
          text:
            "Flag work that isn’t in any run, stretches that run too long without a relief, and runs that spread past your limit."
        }
      ]
    }
  end

  def feature(:rosters) do
    %{
      title: "Rosters",
      scope: :version,
      summary: "Group runs into weekly lines and record which operator holds each line.",
      sections: [
        %{
          name: "Build weekly lines",
          text:
            "Choose one run or a day off for each day of the week. Create a Monday to Friday line in one step from work that isn’t in a line yet."
        },
        %{
          name: "Check each line",
          text:
            "See weekly paid hours, hours over 40, and whether the line has two days off in a row and enough rest between working days."
        },
        %{
          name: "Record who picks each line",
          text:
            "Operators pick lines by seniority outside GTFS Planner. Keep a list of operators and record each pick here."
        },
        %{
          name: "Export assignments",
          text:
            "Download planned operator assignments for other systems. The plan leaves out vacations, sick days and the extraboard."
        }
      ]
    }
  end

  def feature(:evolutions) do
    %{
      title: "Evolutions",
      scope: :version,
      summary:
        "Schedule pathway closures, such as elevator maintenance, and check station access while they apply.",
      sections: [
        %{
          name: "Schedule a closure",
          text:
            "Pick a pathway, the calendar of days it’s closed and the hours, such as the elevator on weekdays 9:00 AM–3:00 PM."
        },
        %{
          name: "Pick pathways on the floorplan",
          text: "See which pathways have closures and which are closed at a time you choose."
        },
        %{
          name: "Check station access",
          text:
            "Choose up to 31 days and see whether every entrance still connects to every platform, and whether a step-free route remains."
        },
        %{
          name: "Include closures in your export",
          text:
            "Closures are saved with your feed export. They use a GTFS extension that isn’t in the official reference, so some trip planners and validators may ignore them."
        }
      ]
    }
  end

  def feature(:feed_url) do
    %{
      title: "Published feed URL",
      scope: :all_versions,
      summary: "Give data consumers one permanent address for your feed.",
      sections: [
        %{
          name: "Copy your permanent URL",
          text:
            "One address that never changes, so trip planners keep reading your latest published feed."
        },
        %{
          name: "See what’s live",
          text:
            "Check which version and export the URL serves now. It can differ from the version you’re editing."
        },
        %{
          name: "Publish a finished export",
          text:
            "After an export finishes and is checked, publish it. If the check found errors, you confirm first and see how many."
        },
        %{
          name: "Know the link won’t break",
          text:
            "Download links from Export expire after a day by default. The published URL keeps serving your feed until you publish a different one."
        }
      ]
    }
  end

  @doc """
  Renders the Coming soon body for one catalog feature.

  `scope_label` is caller-resolved text, such as `This version: Fall 2026` or
  `All versions`. The body describes a future feature and carries no controls, so
  a placeholder never offers an action that cannot work yet. The heading level
  follows the surrounding page: `1` on a standalone placeholder page, `2` under
  the station heading on Evolutions, and `3` under the route and pattern headings
  on Alignment. The outcome list's own heading sits one level below it.

  The section is a design-system page scope (`ds-page`), so it takes the
  application fonts and ink wherever it renders.
  """
  attr :feature, :map, required: true
  attr :scope_label, :string, required: true
  attr :heading_level, :integer, values: [1, 2, 3], default: 1

  def coming_soon(assigns) do
    ~H"""
    <section id="coming-soon" aria-labelledby="coming-soon-title" class="ds-page">
      <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
        <.dynamic_tag
          tag_name={"h#{@heading_level}"}
          id="coming-soon-title"
          class="min-w-0 break-words font-display text-[28px] font-semibold leading-tight tracking-[-0.025em] text-strong"
        >
          {@feature.title}
        </.dynamic_tag>
        <%!-- Text and icon, never colour alone. White with a hairline because the page
        ground is the same grey as `bg-canvas`, which would erase the badge. --%>
        <span
          id="coming-soon-status"
          class="inline-flex items-center gap-1.5 rounded-badge border border-subtle bg-white px-2 py-0.5 text-[13px] font-[650] text-muted"
        >
          <.icon name="hero-clock" class="size-4" /> Coming soon
        </span>
      </div>

      <p id="coming-soon-summary" class="mt-3 max-w-[62ch] text-lg leading-snug text-default">
        {@feature.summary}
      </p>

      <p class="mt-1 text-[13px] text-muted">
        <.scope_line id="coming-soon-scope" icon="hero-square-3-stack-3d">
          {@scope_label}
        </.scope_line>
      </p>

      <.dynamic_tag
        tag_name={"h#{@heading_level + 1}"}
        id="coming-soon-outcomes-title"
        class="mt-9 font-display text-[22px] font-semibold leading-tight tracking-[-0.025em] text-strong"
      >
        What you’ll be able to do
      </.dynamic_tag>

      <ul id="coming-soon-sections" class="mt-4 max-w-[46rem] border-t border-subtle">
        <li :for={section <- @feature.sections} class="border-b border-subtle py-3.5">
          <p class="font-[650] text-strong">{section.name}</p>
          <p class="mt-1 text-default">{section.text}</p>
        </li>
      </ul>
    </section>
    """
  end
end
