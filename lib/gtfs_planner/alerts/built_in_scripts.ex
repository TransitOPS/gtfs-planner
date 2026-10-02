defmodule GtfsPlanner.Alerts.BuiltInScripts do
  @moduledoc """
  The read-only scripts and writing guidelines every organization starts with.

  The eight scripts are the prototype's message script list
  (`.specs/30-service-alerts/evidence/prototype/data.js`) reduced to what the
  spec's fixed placeholder vocabulary can fill. The prototype's `[street]`,
  `[When]`, `[Use instead]`, `[Short headline]`, `[Details for riders]` and
  `[check time]` tokens are not part of that vocabulary - `Message.fill/2` would
  never fill them and `AlertScript.changeset/2` would refuse a script that used
  them - so each one is rewritten as wording that uses only `[route]`,
  `[direction]`, `[stop]`, `[first skipped]`, `[last skipped]`,
  `[alternate stop]`, `[when]`, `[because]` and `[minutes]`.

  A built-in is never editable in place. `Alerts.copy_built_in_script/2` is the
  only way one becomes an organization's own script, which is what keeps the
  defaults uniform across tenants (AC-11, R10).

  The guidelines are the prototype's eight writing guidelines (`data.js`)
  joined into the plain paragraphs a settings textarea holds. An organization
  reads these at revision 0 until `Alerts.save_guidelines/3` stores its own.
  """

  @scripts [
    %{
      key: "detour",
      name: "Detour, stops skipped",
      situation: :detour,
      header_template: "Route [route] detour: [first skipped] to [last skipped] not served",
      description_template:
        "[when], Route [route] buses are detoured[because]. " <>
          "Stops from [first skipped] to [last skipped] are not served."
    },
    %{
      key: "delay",
      name: "Delays",
      situation: :delay,
      header_template: "Route [route] delays of up to [minutes] minutes",
      description_template:
        "Route [route] buses are running up to [minutes] minutes late[because]."
    },
    %{
      key: "stop_moved",
      name: "Stop moved, use nearby stop",
      situation: :stop_moved,
      header_template: "[stop] stop moved. Use [alternate stop]",
      description_template: "[when], boarding for [stop] moves to [alternate stop][because]."
    },
    %{
      key: "stop_closed",
      name: "Stop closed, use nearby stop",
      situation: :stop_closed,
      header_template: "[stop] stop closed. Use [alternate stop]",
      description_template:
        "[when], the [stop] stop is closed[because]. " <>
          "Board Route [route] at [alternate stop] instead."
    },
    %{
      key: "no_service_day",
      name: "No service on a day",
      situation: :cancelled_trips,
      header_template: "No Route [route] service [when]",
      description_template: "Route [route] does not run [when][because]."
    },
    %{
      key: "accessibility",
      name: "Elevator or lift out of service",
      situation: :accessibility,
      header_template: "Elevator out of service at [stop]",
      description_template:
        "The elevator at [stop] is out of service[because]. " <>
          "For a step-free route, use [alternate stop]."
    },
    %{
      key: "rider_information",
      name: "Rider information",
      situation: :service_change,
      header_template: "Service information for Route [route]",
      description_template: "[when], Route [route] service information[because]."
    },
    %{
      key: "suspension",
      name: "Service suspended",
      situation: :suspension,
      header_template: "Route [route] service suspended",
      description_template: "[when], Route [route] buses do not run[because]."
    }
  ]

  # One paragraph per guideline, in the prototype's order, each opening with its
  # title so the textarea reads as a list rather than as a run-on block. The `~s`
  # sigils keep the prototype's own quoted examples readable.
  @guidelines [
    "Lead with the route and the change. Start the short message with the route and what " <>
      ~s|changes: "Route 1 detour", "No Route 7 service Sunday". | <>
      "Riders scan the first few words.",
    "Keep the short message short. Aim for 60 characters or fewer. " <>
      "Apps cut long headlines off, often on one line.",
    "Say when. Every alert says when it starts and ends, with the day for anything not today: " <>
      ~s|"until 6 PM", "Sat Oct 10, 8 AM to 6 PM". | <>
      "If you don't know the end, say when you will update it.",
    "Tell riders what to do. Name the stop to use instead, the other route, or the phone number. " <>
      "An alert without a next step leaves riders stuck.",
    ~s|Name directions by destination. Write "to Lincoln City", not "northbound", "inbound" or "IB".|,
    "Plain words, no codes. Write stop names, not stop numbers; skip internal words like " <>
      ~s|"deadhead", "block" or "pull-out". | <>
      ~s|Write "St" and "Hwy" the way signs do; the read-aloud version spells them out.|,
    ~s|Calm and factual. No capital letters for emphasis, no exclamation marks, no "unfortunately". | <>
      "Apologies belong in the details, once, if at all.",
    ~s|Times the way riders say them. "8 AM", "6:30 PM", "noon". | <>
      ~s|Use "midnight" and "noon" instead of 12 AM and 12 PM.|
  ]

  @guidelines_text Enum.join(@guidelines, "\n\n")

  @typedoc "One built-in script, as `Alerts.list_scripts/1` returns it."
  @type script :: %{
          required(:key) => String.t(),
          required(:name) => String.t(),
          required(:situation) => atom(),
          required(:header_template) => String.t(),
          required(:description_template) => String.t()
        }

  @doc """
  Lists the eight built-in scripts, in the order a settings page shows them.
  """
  @spec scripts() :: [script()]
  def scripts, do: @scripts

  @doc """
  Returns the built-in script with that stable key, or `nil`.

  The keys are the stable strings `Alerts.copy_built_in_script/2` and
  `MessageAnswer.script_key` carry, so they never change with wording.
  """
  @spec script(String.t()) :: script() | nil
  def script(key) when is_binary(key), do: Enum.find(@scripts, &(&1.key == key))
  def script(_key), do: nil

  @doc """
  Returns the recommended guidelines text an organization reads before its first
  save.
  """
  @spec guidelines() :: String.t()
  def guidelines, do: @guidelines_text
end
