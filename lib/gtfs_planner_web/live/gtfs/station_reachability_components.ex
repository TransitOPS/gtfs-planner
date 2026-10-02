defmodule GtfsPlannerWeb.Gtfs.StationReachabilityComponents do
  @moduledoc """
  Pieces the two station reachability pages share, in the TransitOps application
  design system: the on-foot and step-free icons, the indeterminate progress card
  shown while a check runs, and the time and count wording both pages print.

  Called through an explicit import in each page; not part of the global
  `GtfsPlannerWeb.html_helpers/0` import set.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]

  @doc """
  The mark for a way of travelling: feet for on foot, a person using a wheelchair
  for step-free. Heroicons has neither, so both are drawn here.
  """
  attr :mode, :atom, required: true, values: [:walking, :wheelchair]
  attr :class, :any, default: "size-5"

  def mode_icon(%{mode: :walking} = assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M4 16v-2.38C4 11.5 2.97 10.5 3 8c.03-2.72 1.49-6 4.5-6C9.37 2 10 3.8 10 5.5c0 3.11-2 5.66-2 8.68V16a2 2 0 1 1-4 0Z" />
      <path d="M20 20v-2.38c0-2.12 1.03-3.12 1-5.62-.03-2.72-1.49-6-4.5-6C14.63 6 14 7.8 14 9.5c0 3.11 2 5.66 2 8.68V20a2 2 0 1 0 4 0Z" />
      <path d="M16 17h4M4 13h4" />
    </svg>
    """
  end

  def mode_icon(%{mode: :wheelchair} = assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <circle cx="16" cy="4" r="1" />
      <path d="m18 19 1-7-6 1" />
      <path d="m5 8 3-3 5.5 3-2.36 3.5" />
      <path d="M4.24 14.5a5 5 0 0 0 6.88 6" />
      <path d="M13.76 17.5a5 5 0 0 0-6.88-6" />
    </svg>
    """
  end

  @doc """
  The card shown while a check runs. The bar has no value because the run reports
  none; it stands still when the reader asks for reduced motion.
  """
  attr :title, :string, required: true
  slot :inner_block, required: true

  def progress_card(assigns) do
    ~H"""
    <section
      id="reachability-running"
      aria-labelledby="reachability-running-title"
      class="rounded-card border border-info-line bg-info-bg p-5 sm:p-6"
    >
      <div class="flex items-start gap-3">
        <.icon
          name="hero-arrow-path"
          class="mt-0.5 size-5 shrink-0 text-info-fg motion-safe:animate-spin"
        />
        <div class="min-w-0 flex-1">
          <h3 id="reachability-running-title" class="text-lg font-bold text-info-fg">{@title}</h3>
          <p role="status" aria-live="polite" class="mt-1 text-sm text-info-fg">
            {render_slot(@inner_block)}
          </p>
          <div
            role="progressbar"
            aria-label="Checking walks"
            class="ds-indeterminate mt-4 [--ds-indeterminate-fill:var(--color-info-fg)] [--ds-indeterminate-track:white]"
          >
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc "When a run happened, in the format both pages print."
  def format_time(%DateTime{} = time), do: Calendar.strftime(time, "%b %d, %Y at %H:%M")
  def format_time(%NaiveDateTime{} = time), do: Calendar.strftime(time, "%b %d, %Y at %H:%M")
  def format_time(_time), do: nil
end
