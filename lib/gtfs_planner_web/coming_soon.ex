defmodule GtfsPlannerWeb.ComingSoon do
  @moduledoc """
  Shared content and body for destinations that are navigable before they are built.

  Every placeholder surface renders one `coming_soon/1` instance from this fixed
  catalog, so a title, summary, scope and subsection list stay in one place instead
  of being restated per consumer. The caller owns the page shell: it supplies the
  heading level its surrounding page needs and the scope label it can resolve at
  runtime.

  `feature/1` answers for the twelve catalog keys only. Any other key raises, so a
  typo or an unmapped user string cannot render plausible-looking placeholder copy
  for a feature nobody has described.
  """

  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents, only: [status_badge: 1]

  @type scope :: :version | :all_versions

  @type feature :: %{
          title: String.t(),
          summary: String.t(),
          scope: scope(),
          sections: [%{name: String.t(), text: String.t()}]
        }

  @doc """
  Returns the fixed catalog entry for one unbuilt destination.

  Keys, titles, summaries, scopes and subsection lists come from the finalized
  content table in the information-architecture spec.
  """
  @spec feature(atom()) :: feature()
  def feature(:transfers) do
    %{
      title: "Transfers",
      scope: :version,
      summary:
        "Tell trip planners where riders can change vehicles: between stops, routes or two specific trips.",
      sections: [
        %{name: "Transfer list", text: "Review transfers in this version."},
        %{
          name: "New transfer",
          text: "Choose a stop, route or trip pair, then set its type and minimum time."
        },
        %{
          name: "In-seat transfers",
          text: "Review connections where riders stay on board, set on Operations › Blocks."
        }
      ]
    }
  end

  def feature(:blocks) do
    %{
      title: "Blocks",
      scope: :version,
      summary: "Plan which trips each vehicle runs in sequence, one day type at a time.",
      sections: [
        %{name: "Timeline", text: "Arrange trips into vehicle blocks."},
        %{name: "Unassigned trips", text: "Find trips that still need a vehicle block."},
        %{name: "Checks", text: "Find overlaps, short layovers and repositioning problems."},
        %{
          name: "Riders stay on board",
          text: "Mark connections where riders can remain in the vehicle."
        },
        %{
          name: "Deadheads and relief points",
          text: "Plan non-service movements and operator changes."
        }
      ]
    }
  end

  def feature(:runs) do
    %{
      title: "Runs",
      scope: :version,
      summary: "Cut vehicle blocks into each operator’s daily work.",
      sections: [
        %{name: "Duty chart", text: "Review each operator’s work through the day."},
        %{name: "Suggest runs", text: "Review suggested cuts of vehicle blocks."},
        %{name: "Work rules", text: "Set the rules used to form runs."},
        %{name: "Checks", text: "Find runs that break those rules."}
      ]
    }
  end

  def feature(:rosters) do
    %{
      title: "Rosters",
      scope: :version,
      summary: "Group runs into weekly lines and record which operator holds each line.",
      sections: [
        %{name: "Weekly lines", text: "Arrange runs across the week."},
        %{name: "Open work", text: "Find work without an assigned operator."},
        %{name: "Operators", text: "Manage the operators available for assignments."},
        %{name: "Crew export", text: "Download roster and assignment data."}
      ]
    }
  end

  def feature(:flex) do
    %{
      title: "Flex",
      scope: :version,
      summary:
        "Describe on-demand service on your fixed routes, such as drop-off near a stop by request.",
      sections: [
        %{name: "Flex services", text: "Choose the fixed routes covered by each service."},
        %{name: "Area", text: "Set the area served around route stops."},
        %{name: "Boarding", text: "Describe pickup and drop-off arrangements."},
        %{name: "Booking", text: "Set how and when riders book."},
        %{name: "Export preview", text: "Review the GTFS-flex data the service will produce."}
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
        %{name: "Closures", text: "Set which pathways close and when."},
        %{name: "Access check", text: "Check station access during those closures."}
      ]
    }
  end

  def feature(:alignment) do
    %{
      title: "Alignment",
      scope: :version,
      summary: "Draw the path this pattern travels between stops.",
      sections: [
        %{name: "Segment status", text: "Find saved and missing segments between stop visits."},
        %{name: "Generate along streets", text: "Generate a path between stops using streets."},
        %{name: "Edit points", text: "Adjust the points along a segment."},
        %{name: "Shared segments", text: "Review segments used by other patterns."}
      ]
    }
  end

  def feature(:feed_details) do
    %{
      title: "Feed details",
      scope: :version,
      summary: "Describe this version’s feed for data consumers.",
      sections: [
        %{name: "Publisher", text: "Name the feed publisher and website."},
        %{name: "Languages", text: "Set the feed’s languages."},
        %{name: "Service dates", text: "Describe the dates covered by the feed."},
        %{name: "Feed version", text: "Identify the feed release."},
        %{name: "Contact", text: "Provide contact details for feed questions."}
      ]
    }
  end

  def feature(:agencies) do
    %{
      title: "Agencies",
      scope: :version,
      summary: "Manage the agencies that operate this version’s routes.",
      sections: [
        %{name: "Agency list", text: "Review agencies and the routes they operate."},
        %{name: "One timezone", text: "Keep agencies in the version on one timezone."},
        %{name: "Removing an agency", text: "Move its routes before removing it."}
      ]
    }
  end

  def feature(:fares) do
    %{
      title: "Fares",
      scope: :version,
      summary: "Set up fare zones and the fare rules that use them.",
      sections: [
        %{name: "Zones", text: "Group stops into fare zones."},
        %{name: "Fare rules", text: "Set fares by origin, destination and zones crossed."}
      ]
    }
  end

  def feature(:export_defaults) do
    %{
      title: "Export defaults",
      scope: :all_versions,
      summary: "Choose how future exports are written.",
      sections: [
        %{name: "ID formats", text: "Choose identifier formats for exports."},
        %{name: "Stop times between timepoints", text: "Choose how missing times are estimated."},
        %{name: "GTFS-flex files", text: "Choose whether exports include on-demand service data."}
      ]
    }
  end

  def feature(:feed_url) do
    %{
      title: "Published feed URL",
      scope: :all_versions,
      summary: "Give data consumers one permanent address for your feed.",
      sections: [
        %{name: "Feed URL", text: "Find the address consumers will use."},
        %{name: "What’s live", text: "Review the version and export currently served."},
        %{name: "Publishing", text: "Learn how a completed export becomes the public feed."}
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
  on Alignment.
  """
  attr :feature, :map, required: true
  attr :scope_label, :string, required: true
  attr :heading_level, :integer, values: [1, 2, 3], default: 1

  def coming_soon(assigns) do
    ~H"""
    <section
      id="coming-soon"
      aria-labelledby="coming-soon-title"
      class="rounded-box border border-base-300 p-6 sm:p-8"
    >
      <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
        <h1
          :if={@heading_level == 1}
          id="coming-soon-title"
          class="break-words text-2xl font-bold leading-8"
        >
          {@feature.title}
        </h1>
        <h2
          :if={@heading_level == 2}
          id="coming-soon-title"
          class="break-words text-xl font-semibold"
        >
          {@feature.title}
        </h2>
        <h3
          :if={@heading_level == 3}
          id="coming-soon-title"
          class="break-words text-lg font-semibold"
        >
          {@feature.title}
        </h3>
        <.status_badge id="coming-soon-status" status={:coming_soon} label="Coming soon" />
      </div>

      <p id="coming-soon-scope" class="mt-1 text-sm text-base-content/70">{@scope_label}</p>

      <p class="mt-3 max-w-2xl text-sm text-base-content/70">{@feature.summary}</p>

      <p class="mt-6 text-sm font-semibold text-base-content">What it will include</p>

      <ul id="coming-soon-sections" class="mt-2 max-w-2xl space-y-3">
        <li :for={section <- @feature.sections}>
          <p class="text-sm font-medium text-base-content">{section.name}</p>
          <p class="text-sm text-base-content/70">{section.text}</p>
        </li>
      </ul>
    </section>
    """
  end
end
