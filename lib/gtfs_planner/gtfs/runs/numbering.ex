defmodule GtfsPlanner.Gtfs.Runs.Numbering do
  @moduledoc """
  How runs are numbered.

  Pure: it reads its arguments, calls no repository, clock, file or network, and
  writes nothing. It decides numbers; it does not check them against a stored
  set, which is what makes the same numbers reproducible on the page, in the
  export and in a rebuild.

  ## Two different "next" numbers

  The two rules are not the same question and must not answer it the same way.

  `rebuild_prefix/1` answers "where does this agency's numbering start?", and
  uses the **lowest** numeric run ID: the day type already has a scheme, and a
  rebuild should continue it rather than collide with it. Every digit after the
  first becomes a zero, so `1013 → 1000`, `101 → 100` and `7 → 0`. The
  zeroing rather than a fixed thousands block is what lets a three-digit agency
  stay on three digits instead of being pushed to four.

  `next_run_id/1` answers "what number is free right now?", and uses the
  **highest**: a new run added by hand has to sit above everything already in
  use, because anything else could already be a run that is merely not in this
  day type's list.

  A rebuild then numbers from `prefix + 1` upward in sign-on order, so the runs
  it produces are `prefix + 1, prefix + 2, …` and never continue from the
  highest. That distinction is the reason both
  functions exist rather than one parameterised on which end to take.

  ## What counts as numeric

  A run ID is numeric when the **whole** string parses as a non-negative
  integer. `X9` is not, and is ignored by both rules rather than contributing a
  zero: a day type of `["X9"]` has no numeric run, so its prefix is 0 and its
  next number is `"1"`. Leading zeros are accepted as numeric, because they
  parse and a planner who typed `007` meant seven.

  Nothing here can produce an ID the format check rejects **on the rebuild
  path**. The format allows eight characters, the largest possible numeric ID is
  therefore `99999999`, its prefix is `90000000` and every number after it is
  still eight characters.

  `next_run_id/1` is the one place the rule can run past that: a day type
  already holding `99999999` would be offered `100000000`, nine characters, which
  the format rejects. The rule does not say what to do about that and nothing
  here invents an answer — it is reported rather than clamped, because silently
  wrapping back to a low number would collide with a run that is already in use.
  A caller that hits it should surface it, not be handed a plausible wrong
  number. Widening `@run_id_format` would change that argument, which is why
  `valid_run_id?/1` and this module are stated together in the spec.
  """

  @run_id_format ~r/^[A-Za-z0-9-]{1,8}$/

  @doc """
  Whether a term is a usable run ID: one to eight letters, digits or hyphens.

  Takes any term, so `nil`, a number and a struct are all rejected rather than
  raising — it guards a user-supplied value and a crash on a bad one is not a
  validation.
  """
  @spec valid_run_id?(term()) :: boolean()
  def valid_run_id?(run_id) when is_binary(run_id) do
    Regex.match?(@run_id_format, run_id)
  end

  def valid_run_id?(_other), do: false

  @doc """
  The highest numeric run ID in a list, or `0` when there is none.

  Non-numeric IDs are skipped, not treated as zero, so `["X9"]` is `0` for the
  same reason an empty list is.
  """
  @spec highest_numeric([String.t()]) :: non_neg_integer()
  def highest_numeric(run_ids) do
    run_ids
    |> numeric_ids()
    |> case do
      [] -> 0
      numbers -> Enum.max(numbers)
    end
  end

  @doc """
  The next number for a run created outside a rebuild: one above the highest
  numeric ID in use, or `"1"` when there is none.
  """
  @spec next_run_id([String.t()]) :: String.t()
  def next_run_id(run_ids) do
    Integer.to_string(highest_numeric(run_ids) + 1)
  end

  @doc """
  The number a rebuild starts above: the lowest numeric run ID with every digit
  after the first set to zero, or `0` when the day type has no numeric run.

      rebuild_prefix(["1013", "1030", "A1"]) #=> 1000
      rebuild_prefix(["101", "150"])         #=> 100
      rebuild_prefix(["7"])                  #=> 0
      rebuild_prefix(["X"])                  #=> 0
  """
  @spec rebuild_prefix([String.t()]) :: non_neg_integer()
  def rebuild_prefix(run_ids) do
    case numeric_ids(run_ids) do
      [] -> 0
      numbers -> zero_after_first(Enum.min(numbers))
    end
  end

  @doc """
  The next `count` numbers above a prefix, in order.

  A rebuild calls this once with the prefix and the number of runs it is about to
  produce, which is what makes the numbering follow sign-on order: the caller
  zips the two together.

      numeric_after(1000, 3) #=> ["1001", "1002", "1003"]
  """
  @spec numeric_after(non_neg_integer(), pos_integer()) :: [String.t()]
  def numeric_after(prefix, count) do
    Enum.map(1..count//1, &Integer.to_string(prefix + &1))
  end

  # A run ID is numeric when the whole string parses. `Integer.parse/1` returns
  # `{integer, ""}` for a clean parse and either an `:error` or a non-empty
  # remainder otherwise, so both are rejected.
  defp numeric_ids(run_ids) do
    Enum.flat_map(run_ids, fn run_id ->
      case Integer.parse(run_id) do
        {number, ""} when number >= 0 -> [number]
        _otherwise -> []
      end
    end)
  end

  # 1013 -> 1000, 101 -> 100. Dividing by the right power of ten keeps the first
  # digit and drops the rest.
  #
  # A single digit becomes 0, which is the rule's own example and not a rounding
  # accident: with no digits after the first there is no scheme to preserve, so
  # a one-digit run reads the same as no numeric run at all and the rebuild
  # starts from 0. Note this zeroes rather than rounds up — 99999999 gives
  # 90000000, not 10000000 — so the leading digit of the agency's scheme survives
  # a rebuild.
  defp zero_after_first(number) when number < 10, do: 0

  defp zero_after_first(number) do
    divisor = Integer.pow(10, Integer.digits(number) |> length() |> Kernel.-(1))
    div(number, divisor) * divisor
  end
end
