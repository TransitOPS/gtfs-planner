defmodule GtfsPlanner.Alerts.Message do
  @moduledoc """
  Turns an alert's answers and one message script into the text a rider reads
  (AC-12, R10).

  Scripts are data. A template is plain text with `[name]` fill-ins drawn from
  the fixed vocabulary in `@placeholders`, and `fill/2` is one
  `Regex.replace/4` whose callback returns either the fact or the token
  untouched. There is no template engine here, no `EEx`, no `Code.eval_*` and no
  second pass: a fact whose own text contains `[route]` is inserted as that
  literal text and is never filled a second time, and a fact the alert cannot
  answer leaves its placeholder visible for the operator to see.

  Nothing is HTML-escaped here. Alert text is stored as plain text and rendered
  through HEEx interpolation, which escapes on the way out; escaping during the
  fill would store `&amp;` in a message riders read in their transit app. `checks/2`
  flags `<` and `>` as advisory wording problems instead.

  The facts come from the alert's own answers, `Alerts.Recurrence.summary/1` and
  the label map `Alerts.labels_for/2` returns, so a route or stop that no longer
  resolves simply contributes no fact. `facts/2` is a pure function of those
  three inputs: it reads no clock, no network and no row, which is what makes
  `digest/1` a stable answer to "has anything the text was generated from
  changed?".

  `digest/1` hashes the sorted facts, so `review_wording?/2` can tell customized
  text the operator wrote from text a script produced, and flag the first for a
  second look after a later answer changed a fact. It never rewrites text.

  All of this is advisory and reversible: nothing here writes an alert (INV-1),
  and `Alerts.save_draft/4` is still the only path that stores message text.
  Every time in a fact is the civil time the operator answered (CR-7).
  """

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Listing
  alias GtfsPlanner.Alerts.MessageAnswer
  alias GtfsPlanner.Alerts.Recurrence
  alias GtfsPlanner.Alerts.ScopeAnswer

  # The whole vocabulary. A template using anything else is rejected on save by
  # `unknown_placeholders/1`, so a script can never introduce a token the fill
  # would silently skip. Spelled out rather than as a `~w` sigil so the
  # multi-word names are visible to a reader rather than sitting behind an
  # escape.
  @placeholders [
    "route",
    "direction",
    "stop",
    "first skipped",
    "last skipped",
    "alternate stop",
    "when",
    "because",
    "minutes"
  ]

  # What `fill/2` recognizes: a bracketed run of lowercase letters and spaces,
  # which is every placeholder above and nothing else.
  @fill_token ~r/\[([a-z ]+)\]/

  # `unknown_placeholders/1` is deliberately wider than `@fill_token`: it reads
  # any bracketed run, so a script that spells a fill-in wrongly ("[When]",
  # "[Use instead]") is rejected rather than passed through to a template that
  # could never fill it.
  @any_token ~r/\[([^\[\]]+)\]/

  # Riders see the header first and apps cut it to about one line. No authority
  # sets a limit; 60 is the length the research found Transit's alerts mostly fit
  # in and the one the organization guidelines are written against.
  @header_limit 60

  # How several affected routes read in one sentence, and how `checks/2` reads
  # them apart again.
  @join " and "

  # Rider-facing phrases for the GTFS-RT causes an operator can choose. The two
  # causes that say nothing ("not known yet", "other reason") deliberately have
  # no phrase: a `[because]` filled with one of them would tell a rider nothing,
  # so the placeholder stays visible instead.
  @cause_phrases %{
    accident: "a crash",
    construction: "roadwork",
    demonstration: "a demonstration",
    holiday: "the holiday",
    maintenance: "maintenance",
    medical_emergency: "a medical emergency",
    police_activity: "police activity",
    special_event: "a special event",
    strike: "a strike",
    technical_problem: "a vehicle or equipment problem",
    weather: "weather"
  }

  @typedoc """
  The facts one alert offers a template: a placeholder name mapped to the text
  that replaces it. A name that is absent has no answer the alert can give, so
  `fill/2` leaves that token visible.
  """
  @type facts :: %{optional(String.t()) => String.t()}

  @typedoc "One script's templates, as `Alerts.list_scripts/1` returns it."
  @type script_option :: %{
          required(:key) => String.t(),
          required(:header_template) => String.t(),
          required(:description_template) => String.t(),
          optional(any()) => any()
        }

  @doc """
  Lists the placeholder names a template may use, in the order a settings page
  should present them.

  This is the same list `unknown_placeholders/1` checks against, so a script
  validated through that function can only contain names this returns.
  """
  @spec placeholders() :: [String.t()]
  def placeholders, do: @placeholders

  @doc """
  Collects every placeholder in `template` that is not in the vocabulary.

  Used when an organization script is saved (AC-11): a template naming
  `[street]` or `[When]` is refused rather than stored as wording that could
  never be filled. Duplicates are reported once, in the order they appear.
  """
  @spec unknown_placeholders(String.t() | nil) :: [String.t()]
  def unknown_placeholders(template) when is_binary(template) do
    @any_token
    |> Regex.scan(template)
    |> Enum.map(fn [_match, name] -> name end)
    |> Enum.reject(&(&1 in @placeholders))
    |> Enum.uniq()
  end

  def unknown_placeholders(_template), do: []

  @doc """
  Replaces each `[name]` in `template` with the matching fact, in one pass.

  A fact that is missing or blank leaves its token exactly as written, so the
  operator sees what could not be filled, and so does a name outside the
  vocabulary even when `facts` happens to hold it. A fact is inserted literally:
  the replacement is not rescanned, so a stop or route named `[route]` appears in
  the text as that text and the fill does not run again over it.

  A `nil` template is no template, and fills to the empty text.
  """
  @spec fill(String.t() | nil, facts()) :: String.t()
  def fill(template, facts) when is_binary(template) and is_map(facts) do
    Regex.replace(@fill_token, template, fn token, name ->
      with true <- name in @placeholders,
           value when is_binary(value) <- Map.get(facts, name),
           true <- String.trim(value) != "" do
        value
      else
        _unfilled -> token
      end
    end)
  end

  def fill(_template, _facts), do: ""

  @doc """
  Builds the facts one alert offers a script's fill-ins.

  `labels` is the map `Alerts.labels_for/2` returns, whose `routes`, `stop` and
  `trips` keys map a row UUID to its rider-facing label. It may also carry a
  `:direction` string - "to Lincoln City", the destination a rider would use -
  because the direction name lives on the route's trips, which a pure function
  over the alert cannot read; the caller that knows the direction passes it.

  A fact with no answer is left out of the map rather than filled with `""`,
  which is what lets `fill/2` keep the placeholder visible. Labels are read in
  the alert's own stored order, so "first skipped" and "last skipped" are the
  ends of the stretch the operator chose and not an arbitrary query order.
  """
  @spec facts(Alert.t(), map()) :: facts()
  def facts(%Alert{} = alert, labels) when is_map(labels) do
    stops = skipped_stop_ids(alert)
    stop_labels = Enum.map(stops, &label(labels, :stops, &1))

    %{
      "route" => route_fact(alert, labels),
      "direction" => present(Map.get(labels, :direction)),
      "stop" => first_present(stop_labels),
      "first skipped" => List.first(stop_labels),
      "last skipped" => List.last(stop_labels),
      "alternate stop" => label(labels, :stops, alternative_stop_id(alert)),
      "when" => when_fact(alert),
      "because" => because_fact(alert),
      "minutes" => minutes_fact(alert)
    }
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  Hashes the facts a message was generated from.

  The digest is a lowercase hex SHA-256 of the facts sorted by placeholder name,
  so two alerts with the same answers produce the same digest and any change to
  any fact changes it. It is stored on the message answer, which is what lets
  `review_wording?/2` notice a later answer making earlier text stale.
  """
  @spec digest(facts()) :: String.t()
  def digest(facts) when is_map(facts) do
    facts
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Fills a script's two templates for one alert and returns the text with the
  digest it was generated from.

  The caller stores the result through `Alerts.save_draft/4`; nothing here writes.
  """
  @spec generate(Alert.t(), script_option(), map()) :: %{
          header: String.t(),
          description: String.t(),
          fact_digest: String.t()
        }
  def generate(%Alert{} = alert, script, labels)
      when is_map(script) and is_map(labels) do
    facts = facts(alert, labels)

    %{
      header: fill(Map.get(script, :header_template), facts),
      description: fill(Map.get(script, :description_template), facts),
      fact_digest: digest(facts)
    }
  end

  @doc """
  Answers whether an operator's own wording needs a second look.

  True only for text marked `customized` whose stored digest no longer matches
  the alert's current facts. Script-generated text is never flagged - it is
  regenerated on request instead of reviewed - and neither is customized text
  that still agrees with the answers.
  """
  @spec review_wording?(Alert.t(), map()) :: boolean()
  def review_wording?(%Alert{message: %MessageAnswer{customized: true} = message} = alert, labels)
      when is_map(labels) do
    message.fact_digest != digest(facts(alert, labels))
  end

  def review_wording?(%Alert{}, _labels), do: false

  @doc """
  Runs the advisory wording checks over one message answer.

  Four observations, each advisory and each independently reported: a header
  longer than #{@header_limit} characters, a header that names no route or stop
  the alert is about, a description that does not carry the alert's `when` text,
  and any `<` or `>` in either field. A check that cannot be made - a header
  that names no target because the alert is system-wide, or a description with no
  `when` fact to find - reports `ok?`, because there is nothing to advise about.

  Nothing consumes this as a gate: `Alerts.save_draft/4` does not read it, and an
  operator may save a message that fails every check here.
  """
  @spec checks(MessageAnswer.t(), facts()) :: [%{key: atom(), ok?: boolean(), text: String.t()}]
  def checks(%MessageAnswer{} = message, facts) when is_map(facts) do
    header = present(message.header) || ""
    description = present(message.description) || ""
    when_text = present(Map.get(facts, "when"))

    [
      header_length_check(header),
      target_check(header, facts),
      when_check(description, when_text),
      plain_text_check([header, description])
    ]
  end

  # -- Checks --------------------------------------------------------------

  defp header_length_check(header) do
    length = String.length(header)

    %{
      key: :short,
      ok?: length <= @header_limit,
      text:
        if(length <= @header_limit,
          do: "Short message is #{length} characters.",
          else:
            "Short message is #{length} characters. Apps may cut it off after about #{@header_limit}."
        )
    }
  end

  defp target_check(header, facts) do
    targets = target_labels(facts)
    named? = targets == [] or Enum.any?(targets, &String.contains?(header, &1))

    %{
      key: :target,
      ok?: named?,
      text:
        if(named?,
          do: "Names the route or stop this alert is about.",
          else: "Name the route or stop this alert is about, the way riders ask for it."
        )
    }
  end

  defp when_check(_description, nil),
    do: %{key: :when, ok?: true, text: "No when answer to check yet."}

  defp when_check(description, when_text) do
    %{
      key: :when,
      ok?: String.contains?(description, when_text),
      text:
        if(String.contains?(description, when_text),
          do: "Says when.",
          else: "Say when this applies. Riders look for the day and the times."
        )
    }
  end

  defp plain_text_check(fields) do
    markup? = Enum.any?(fields, &String.contains?(&1, ["<", ">"]))

    %{
      key: :plain_text,
      ok?: not markup?,
      text:
        if(markup?,
          do: "Remove < and >. Rider messages are plain text and apps show those characters.",
          else: "Plain text, no markup."
        )
    }
  end

  # The labels the header could name, split back apart from the sentence
  # `facts/2` joined them into, so naming one of several affected routes is
  # enough to pass.
  defp target_labels(facts) do
    Enum.flat_map(facts, fn
      {"route", value} -> String.split(value, @join, trim: true)
      {"stop", value} -> [value]
      _other -> []
    end)
  end

  # -- Facts ---------------------------------------------------------------

  # Affected routes read in the alert's own stored order, joined into one
  # phrase. An alert that names no route - a system-wide alert - has no route
  # fact, so a route template leaves `[route]` visible rather than claiming
  # something about routes the alert does not name.
  defp route_fact(%Alert{} = alert, labels) do
    alert
    |> Listing.referenced_ids()
    |> Map.fetch!(:routes)
    |> Enum.map(&label(labels, :routes, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> join_names()
  end

  # The stops a rider does not get served, in the order the operator chose them:
  # a detour stretch's two ends first, otherwise the chosen stops, otherwise the
  # stops named by route/stop pairs.
  defp skipped_stop_ids(%Alert{scope: %ScopeAnswer{} = scope}) do
    stretch = List.wrap(scope.stretch_from_stop_id) ++ List.wrap(scope.stretch_to_stop_id)
    chosen = List.wrap(scope.stop_ids)
    pairs = Enum.map(List.wrap(scope.route_stop_pairs), & &1.stop_id)

    Enum.uniq(
      cond do
        Enum.all?(stretch, &present(&1)) and stretch != [] -> stretch
        Enum.any?(chosen, &present(&1)) -> chosen
        true -> pairs
      end
    )
  end

  defp skipped_stop_ids(%Alert{}), do: []

  defp alternative_stop_id(%Alert{scope: %ScopeAnswer{} = scope}), do: scope.alternative_stop_id
  defp alternative_stop_id(%Alert{}), do: nil

  defp label(labels, table, id) do
    with id when is_binary(id) <- id,
         %{} = rows when not is_nil(rows) <- Map.get(labels, table),
         value when is_binary(value) <- Map.get(rows, id) do
      present(value)
    else
      _unknown -> nil
    end
  end

  defp when_fact(%Alert{} = alert) do
    case alert.timing |> Recurrence.summary() |> present() do
      nil -> nil
      summary -> summary
    end
  end

  # The prototype's phrasing, so `[because]` reads correctly wherever a template
  # places it: an explanation, not a bare noun. The operator's own words win over
  # the cause's phrase.
  defp because_fact(%Alert{} = alert) do
    explanation = present(alert.cause_detail) || Map.get(@cause_phrases, alert.cause)

    if explanation, do: " because of " <> explanation
  end

  defp minutes_fact(%Alert{timing: %{delay_minutes: minutes}}) when is_integer(minutes) do
    Integer.to_string(minutes)
  end

  defp minutes_fact(%Alert{}), do: nil

  defp first_present([value | _rest]), do: value
  defp first_present([]), do: nil

  defp join_names([]), do: nil
  defp join_names([name]), do: name
  defp join_names(names), do: Enum.join(names, @join)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
