defmodule GtfsPlanner.Gtfs.Runs.Day do
  @moduledoc """
  Composes one day's runs, findings and figures from its blocks and its trip
  assignments.

  This is **the** derivation of a day's runs. The page, the plan and the
  export all read this result; none of them walks blocks,
  groups pieces or recomputes a figure. A second route to the same numbers would
  be a second answer to the question the page is asking, and the two would drift
  the first time either changed.

  Pure: it calls `Runs.Pieces`, `Runs.WorkTime` and `Runs.Checks` and nothing
  else, reads no repository, clock, file or network, and writes nothing.

  ## What it composes

      Pieces.derive/2       blocks + assignments → pieces, uncovered, boundaries
      WorkTime.compute/3    per run             → duty, breaks, segments
      Checks.run_findings/5 per run             → limit and reachability findings
      Checks.boundary_findings/1                → handovers away from relief
      Checks.uncovered_finding/1                → work no run covers

  Pieces are grouped by `run_id` across the whole day, so a run that serves two
  blocks is one run with two pieces — which is what makes `:straight` and
  `:split` meaningful at all. A run's pieces are sorted by start and the runs
  themselves by sign-on, then by run ID, so the page's order is this module's
  order and two runs signing on together come out in a fixed sequence.

  A boundary finding is attached to **every run it names** and appears once in
  the day's list. That is deliberate rather than a convenience: a handover away
  from a relief point is a problem with both operators at it, and a planner who
  opened only one of those runs still has to see it. Counting is by severity
  over the day's list, which counts each finding once.

  ## Figures

  `straight_share` counts only the runs that had a choice. A one-piece run is
  neither straight nor split — there was no break to make it one or the other —
  so it is in the denominator's absence, not in its numerator: the share is
  `straight ÷ (straight + split)`, and `nil` when a day has no such run at all,
  because zero of nothing is not a percentage. `vehicle_share` is
  `vehicle_secs ÷ paid_secs` over the whole day and is `nil` when nothing is
  paid. Both are rounded to whole percent.

  `axis` is the span the page draws: the earliest sign-on and the latest
  sign-off of the runs, widened by the earliest start and latest end of any
  uncovered segment, so unassigned work is on the chart and not hidden behind
  the runs. It is `nil` when the day has neither.
  """

  alias GtfsPlanner.Gtfs.Runs.Checks
  alias GtfsPlanner.Gtfs.Runs.Pieces
  alias GtfsPlanner.Gtfs.Runs.WorkTime
  alias GtfsPlanner.Wording

  @type run :: %{
          run_id: String.t(),
          pieces: [map()],
          work: WorkTime.t(),
          findings: [Checks.finding()]
        }

  @type stats :: %{
          runs: non_neg_integer(),
          by_type: %{
            one_piece: non_neg_integer(),
            straight: non_neg_integer(),
            split: non_neg_integer()
          },
          straight_share: 0..100 | nil,
          paid_secs: non_neg_integer(),
          vehicle_secs: non_neg_integer(),
          vehicle_share: 0..100 | nil,
          longest_spread: %{run_id: String.t(), secs: non_neg_integer()} | nil,
          uncovered: %{trips: non_neg_integer(), secs: non_neg_integer()},
          problems: %{
            errors: non_neg_integer(),
            warnings: non_neg_integer(),
            notices: non_neg_integer()
          }
        }

  @type derived :: %{
          runs: [run()],
          uncovered: [map()],
          findings: [Checks.finding()],
          stats: stats(),
          axis: %{start_secs: integer(), end_secs: integer()} | nil
        }

  @doc """
  Composes one day's runs and figures.

  `blocks` are the day's block inputs, `assignments` maps a trip's UUID to the
  run that serves it, and `context` and `crew` are the version's own planning
  inputs. An empty day is not an error: it has no runs, zero figures and no
  axis.
  """
  @spec derive([map()], %{Ecto.UUID.t() => String.t()}, map(), map()) :: derived()
  def derive(blocks, assignments, context, crew) do
    %{pieces: pieces, uncovered: uncovered, boundaries: boundaries} =
      Pieces.derive(blocks, assignments)

    boundary_findings = Checks.boundary_findings(boundaries)

    built =
      pieces
      # A piece with no run is uncovered work, and it is reported as such rather
      # than as a run called `nil`.
      |> Enum.reject(&is_nil(&1.run_id))
      |> Enum.group_by(& &1.run_id)
      |> Enum.map(fn {run_id, run_pieces} ->
        run_pieces = Enum.sort_by(run_pieces, & &1.start_secs)
        work = WorkTime.compute(run_pieces, context, crew)
        own = Checks.run_findings(run_id, run_pieces, work, context, crew)

        # A handover finding belongs to every run it names, not just the first.
        # `own` is carried alongside so the day's list can count each boundary
        # finding once however many runs it is attached to.
        run = %{
          run_id: run_id,
          pieces: run_pieces,
          work: work,
          findings: own ++ Enum.filter(boundary_findings, &(run_id in &1.run_ids))
        }

        {run, own}
      end)
      |> Enum.sort_by(fn {run, _own} -> {run.work.sign_on_secs, run.run_id} end)

    runs = Enum.map(built, &elem(&1, 0))
    uncovered_findings = Checks.uncovered_finding(uncovered)

    findings =
      by_severity(Enum.flat_map(built, &elem(&1, 1)) ++ boundary_findings ++ uncovered_findings)

    %{
      runs: runs,
      uncovered: uncovered,
      findings: findings,
      stats: stats(runs, uncovered, findings),
      axis: axis(runs, uncovered)
    }
  end

  # Errors first, then warnings, then notices, as `Runs.Checks` orders them, so a
  # caller that truncates the day's list keeps what stops a plan being published.
  defp by_severity(findings) do
    findings
    |> Enum.with_index()
    |> Enum.sort_by(fn {finding, index} -> {rank(finding.severity), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp rank(:error), do: 0
  defp rank(:warning), do: 1
  defp rank(:notice), do: 2

  defp stats(runs, uncovered, findings) do
    by_type =
      Enum.reduce(runs, %{one_piece: 0, straight: 0, split: 0}, fn run, acc ->
        Map.update!(acc, run.work.type, &(&1 + 1))
      end)

    straight = by_type.straight
    split = by_type.split

    paid_secs = runs |> Enum.map(& &1.work.paid_secs) |> Enum.sum()
    vehicle_secs = runs |> Enum.map(& &1.work.vehicle_secs) |> Enum.sum()

    %{
      runs: length(runs),
      by_type: by_type,
      # Only the runs that had a choice count; a one-piece run is in neither.
      straight_share: share(straight, straight + split),
      paid_secs: paid_secs,
      vehicle_secs: vehicle_secs,
      vehicle_share: share(vehicle_secs, paid_secs),
      longest_spread: longest_spread(runs),
      uncovered: %{
        trips: uncovered |> Enum.flat_map(& &1.trips) |> length(),
        secs: uncovered |> Enum.map(&(&1.end_secs - &1.start_secs)) |> Enum.sum()
      },
      problems: %{
        errors: count(findings, :error),
        warnings: count(findings, :warning),
        notices: count(findings, :notice)
      }
    }
  end

  # Zero of nothing is not a percentage, and the page shows the nil as a dash, so
  # the caller of `Wording.percent/2` keeps that one case.
  defp share(_part, 0), do: nil
  defp share(part, whole), do: Wording.percent(part, whole)

  defp count(findings, severity), do: Enum.count(findings, &(&1.severity == severity))

  defp longest_spread([]), do: nil

  defp longest_spread(runs) do
    # The runs are already in a fixed order and `max_by` keeps the first of equal
    # values, so two runs spreading the same seconds always name the same one.
    longest = Enum.max_by(runs, & &1.work.spread_secs)
    %{run_id: longest.run_id, secs: longest.work.spread_secs}
  end

  defp axis([], []), do: nil

  defp axis(runs, uncovered) do
    spans =
      Enum.map(runs, &{&1.work.sign_on_secs, &1.work.sign_off_secs}) ++
        Enum.map(uncovered, &{&1.start_secs, &1.end_secs})

    {start, _} = Enum.min(spans)
    {_, finish} = Enum.max(spans)

    %{start_secs: start, end_secs: finish}
  end
end
