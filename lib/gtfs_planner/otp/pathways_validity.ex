defmodule GtfsPlanner.Otp.PathwaysValidity do
  @moduledoc """
  Runs deterministic OTP in-session validity checks for pathways validation.
  """

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Otp.Runtime.Session
  alias GtfsPlanner.Validations.WalkabilitySuite

  @typedoc "Suite-level progress payload emitted through :status_callback."
  @type suite_progress_payload :: %{
          required(:scope) => :suite,
          required(:phase) => :running | :finishing | :finished,
          required(:completed) => non_neg_integer(),
          required(:total) => non_neg_integer(),
          optional(:test_case_id) => Ecto.UUID.t()
        }

  @typedoc "Normalized route query output for a single walkability test case."
  @type case_query_output :: %{
          required(:route_exists) => boolean(),
          required(:duration_seconds) => number() | nil,
          required(:distance_meters) => number() | nil
        }

  @typedoc "Single case scoring outcome with explicit failure attribution."
  @type case_scoring_output :: %{
          required(:status) => :passed | :failed,
          optional(:failure_category) => :query_failure | :scoring_failure,
          optional(:details) => map()
        }

  @typedoc "Deterministic suite execution summary."
  @type run_summary :: %{
          required(:total) => non_neg_integer(),
          required(:passed) => non_neg_integer(),
          required(:failed) => non_neg_integer(),
          required(:query_failure) => non_neg_integer(),
          required(:scoring_failure) => non_neg_integer()
        }

  @typedoc "Current and forward-compatible in-session run result payload."
  @type run_result ::
          %{required(:suite_meta) => map(), required(:selected_test_case_ids) => [Ecto.UUID.t()]}
          | %{
              required(:suite_meta) => map(),
              required(:selected_test_case_ids) => [Ecto.UUID.t()],
              required(:summary) => run_summary(),
              required(:cases) => [map()]
            }

  @graphql_walk_plan_query """
  query WalkPlan($fromLat: Float!, $fromLon: Float!, $toLat: Float!, $toLon: Float!, $wheelchair: Boolean) {
    plan(
      from: { lat: $fromLat, lon: $fromLon }
      to: { lat: $toLat, lon: $toLon }
      transportModes: [{ mode: WALK }]
      numItineraries: 1
      wheelchair: $wheelchair
    ) {
      itineraries {
        duration
        walkDistance
      }
    }
  }
  """

  @spec run_in_session(Session.t(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, run_result()} | {:error, map()}
  def run_in_session(%Session{} = session, organization_id, gtfs_version_id, opts \\ []) do
    case WalkabilitySuite.select_suite(organization_id, gtfs_version_id) do
      {:ok, %{suite: [], invalid_cases: _invalid_cases, meta: suite_meta}} ->
        {:error,
         %{
           reason: :no_walkability_tests,
           organization_id: organization_id,
           gtfs_version_id: gtfs_version_id,
           suite_meta: suite_meta,
           selected_test_case_ids: []
         }}

      {:ok, %{suite: suite, invalid_cases: _invalid_cases, meta: suite_meta}} ->
        status_callback = Keyword.get(opts, :status_callback, nil)

        request_fun =
          Keyword.get(opts, :request_fun, fn graphql_url, request_opts ->
            Req.post(Keyword.merge(request_opts, url: graphql_url))
          end)

        selected_test_case_ids = Enum.map(suite, & &1.test_case_id)
        selected_stop_ids = suite |> Enum.map(& &1.stop_id) |> Enum.uniq()
        destination_stops_by_stop_id =
          build_destination_stops_by_stop_id(organization_id, gtfs_version_id, selected_stop_ids)

        total = length(suite)

        cases =
          suite
          |> Enum.with_index(0)
          |> Enum.map(fn {suite_case, completed} ->
            emit_status(status_callback, %{
              scope: :suite,
              phase: :running,
              completed: completed,
              total: total,
              test_case_id: suite_case.test_case_id
            })

            execute_case(suite_case, destination_stops_by_stop_id, session.graphql_url, request_fun)
          end)

        emit_status(status_callback, %{
          scope: :suite,
          phase: :finishing,
          completed: total,
          total: total
        })

        summary = summarize(cases)

        result = %{
          suite_meta: suite_meta,
          selected_test_case_ids: selected_test_case_ids,
          summary: summary,
          cases: cases
        }

        emit_status(status_callback, %{
          scope: :suite,
          phase: :finished,
          completed: total,
          total: total
        })

        {:ok, result}
    end
  end

  @spec execute_case(map(), map(), String.t(), function()) :: map()
  defp execute_case(suite_case, destination_stops_by_stop_id, graphql_url, request_fun) do
    case resolve_destination_coordinates(destination_stops_by_stop_id, suite_case.stop_id) do
      {:error, reason} ->
        classify_case_outcome(suite_case.test_case_id, {:query_failure, reason})

      {:ok, destination} ->
        with {:ok, route_output} <- execute_walk_query(suite_case, destination, graphql_url, request_fun),
             {:ok, wheelchair_output} <-
               maybe_execute_wheelchair_query(
                 suite_case,
                 destination,
                 graphql_url,
                 request_fun
               ) do
          classify_case_outcome(
            suite_case.test_case_id,
            score_case(suite_case, route_output, wheelchair_output)
          )
        else
          {:error, reason} ->
            classify_case_outcome(suite_case.test_case_id, {:query_failure, reason})
        end
    end
  end

  @spec resolve_destination_coordinates(%{optional(String.t()) => Stop.t()}, String.t()) ::
          {:ok, %{to_lat: float(), to_lon: float()}} | {:error, map()}
  defp resolve_destination_coordinates(destination_stops_by_stop_id, stop_id) do
    case Map.get(destination_stops_by_stop_id, stop_id) do
      nil ->
        {:error, %{reason: :missing_destination_stop, stop_id: stop_id}}

      %Stop{stop_lat: stop_lat, stop_lon: stop_lon} ->
        case {normalize_coordinate(stop_lat), normalize_coordinate(stop_lon)} do
          {to_lat, to_lon} when is_float(to_lat) and is_float(to_lon) ->
            {:ok, %{to_lat: to_lat, to_lon: to_lon}}

          _other ->
            {:error, %{reason: :invalid_destination_coordinates, stop_id: stop_id}}
        end
    end
  end

  @spec execute_walk_query(map(), map(), String.t(), function()) ::
          {:ok, case_query_output()} | {:error, map()}
  defp execute_walk_query(suite_case, destination, graphql_url, request_fun) do
    request_payload =
      build_walk_plan_request(
        suite_case.address_lat,
        suite_case.address_lon,
        destination.to_lat,
        destination.to_lon,
        nil
      )

    execute_plan_request(graphql_url, request_payload, request_fun)
  end

  @spec maybe_execute_wheelchair_query(map(), map(), String.t(), function()) ::
          {:ok, case_query_output() | nil} | {:error, map()}
  defp maybe_execute_wheelchair_query(
         %{expected_wheelchair_accessible: expected_wheelchair_accessible},
         _destination,
         _graphql_url,
         _request_fun
       )
       when expected_wheelchair_accessible not in [true, false] do
    {:ok, nil}
  end

  defp maybe_execute_wheelchair_query(suite_case, destination, graphql_url, request_fun) do
    request_payload =
      build_wheelchair_plan_request(
        suite_case.address_lat,
        suite_case.address_lon,
        destination.to_lat,
        destination.to_lon
      )

    execute_plan_request(graphql_url, request_payload, request_fun)
  end

  @spec build_wheelchair_plan_request(float(), float(), float(), float()) ::
          %{required(:query) => String.t(), required(:variables) => map()}
  defp build_wheelchair_plan_request(from_lat, from_lon, to_lat, to_lon) do
    build_walk_plan_request(from_lat, from_lon, to_lat, to_lon, true)
  end

  @spec build_walk_plan_request(float(), float(), float(), float(), boolean() | nil) ::
          %{required(:query) => String.t(), required(:variables) => map()}
  defp build_walk_plan_request(from_lat, from_lon, to_lat, to_lon, wheelchair) do
    %{
      query: @graphql_walk_plan_query,
      variables: %{
        "fromLat" => from_lat,
        "fromLon" => from_lon,
        "toLat" => to_lat,
        "toLon" => to_lon,
        "wheelchair" => wheelchair
      }
    }
  end

  @spec execute_plan_request(String.t(), %{required(:query) => String.t(), required(:variables) => map()}, function()) ::
          {:ok, case_query_output()} | {:error, map()}
  defp execute_plan_request(graphql_url, request_payload, request_fun) do
    case execute_graphql_request(graphql_url, request_payload, request_fun) do
      {:ok, body} ->
        extract_route(body)

      {:error, {:query_failure, details}} ->
        {:error, details}
    end
  end

  @spec execute_graphql_request(String.t(), %{required(:query) => String.t(), required(:variables) => map()}, function()) ::
          {:ok, term()} | {:error, {:query_failure, map()}}
  defp execute_graphql_request(graphql_url, request_payload, request_fun) do
    request_opts = [json: request_payload]

    case request_fun.(graphql_url, request_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status >= 200 and status < 300 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:query_failure, %{reason: :non_2xx_response, status: status, body: body}}}

      {:error, error} ->
        {:error, {:query_failure, %{reason: :transport_error, details: inspect(error)}}}

      unexpected ->
        {:error,
         {:query_failure, %{reason: :unexpected_request_result, details: inspect(unexpected)}}}
    end
  end

  @spec extract_route(term()) :: {:ok, case_query_output()} | {:error, map()}
  defp extract_route(%{"data" => %{"plan" => %{"itineraries" => itineraries}}})
       when is_list(itineraries) do
    extract_route_from_itineraries(itineraries)
  end

  defp extract_route(body),
    do: {:error, %{reason: :invalid_graphql_payload, body: body}}

  @spec extract_route_from_itineraries([map()]) :: {:ok, case_query_output()} | {:error, map()}
  defp extract_route_from_itineraries([]) do
    {:ok, normalize_route_output(false, nil, nil)}
  end

  defp extract_route_from_itineraries([first_itinerary | _rest]) do
    extract_first_itinerary(first_itinerary)
  end

  @spec extract_first_itinerary(map()) :: {:ok, case_query_output()} | {:error, map()}
  defp extract_first_itinerary(%{"duration" => duration, "walkDistance" => walk_distance}) do
    {:ok, normalize_route_output(true, duration, walk_distance)}
  end

  defp extract_first_itinerary(first_itinerary) do
    {:error, %{reason: :invalid_graphql_payload, body: first_itinerary}}
  end

  @spec normalize_route_output(boolean(), number() | nil, number() | nil) :: case_query_output()
  defp normalize_route_output(route_exists, duration_seconds, distance_meters) do
    %{
      route_exists: route_exists,
      duration_seconds: duration_seconds,
      distance_meters: distance_meters
    }
  end

  @spec score_case(map(), case_query_output(), case_query_output() | nil) ::
          {:passed, case_query_output(), case_query_output() | nil}
          | {:scoring_failure, %{required(:mismatches) => [map()]}, case_query_output(),
             case_query_output() | nil}
  defp score_case(suite_case, route_output, wheelchair_output) do
    mismatches =
      suite_case
      |> score_regular_route(route_output)
      |> score_wheelchair_route(suite_case, wheelchair_output)

    case mismatches do
      [] -> {:passed, route_output, wheelchair_output}
      _non_empty -> {:scoring_failure, %{mismatches: mismatches}, route_output, wheelchair_output}
    end
  end

  @spec classify_case_outcome(Ecto.UUID.t(),
          {:query_failure, map()}
          | {:passed, case_query_output(), case_query_output() | nil}
          | {:scoring_failure, map(), case_query_output(), case_query_output() | nil}
        ) :: map()
  defp classify_case_outcome(test_case_id, {:query_failure, details}) do
    %{
      test_case_id: test_case_id,
      status: :failed,
      failure_category: :query_failure,
      details: details
    }
  end

  defp classify_case_outcome(test_case_id, {:passed, route_output, wheelchair_output}) do
    %{
      test_case_id: test_case_id,
      status: :passed,
      route_output: route_output,
      wheelchair_output: wheelchair_output
    }
  end

  defp classify_case_outcome(
         test_case_id,
         {:scoring_failure, details, route_output, wheelchair_output}
       ) do
    %{
      test_case_id: test_case_id,
      status: :failed,
      failure_category: :scoring_failure,
      route_output: route_output,
      wheelchair_output: wheelchair_output,
      details: details
    }
  end

  @spec score_wheelchair_route([map()], map(), case_query_output() | nil) :: [map()]
  defp score_wheelchair_route(mismatches, suite_case, wheelchair_output) do
    maybe_add_wheelchair_mismatch(mismatches, suite_case, wheelchair_output)
  end

  @spec score_regular_route(map(), case_query_output()) :: [map()]
  defp score_regular_route(suite_case, route_output) do
    []
    |> maybe_add_traversable_mismatch(suite_case, route_output)
    |> maybe_add_duration_mismatch(suite_case, route_output)
    |> maybe_add_distance_mismatch(suite_case, route_output)
  end

  @spec maybe_add_traversable_mismatch([map()], map(), case_query_output()) :: [map()]
  defp maybe_add_traversable_mismatch(
         mismatches,
         %{expected_traversable: expected_traversable},
         _route_output
       )
       when expected_traversable not in [true, false],
       do: mismatches

  defp maybe_add_traversable_mismatch(mismatches, suite_case, route_output) do
    if route_output.route_exists == suite_case.expected_traversable do
      mismatches
    else
      [
        %{kind: :expected_traversable, expected: suite_case.expected_traversable, actual: route_output.route_exists}
        | mismatches
      ]
    end
  end

  @spec maybe_add_duration_mismatch([map()], map(), case_query_output()) :: [map()]
  defp maybe_add_duration_mismatch(mismatches, suite_case, route_output) do
    mismatches
    |> maybe_add_min_duration_mismatch(suite_case, route_output)
    |> maybe_add_max_duration_mismatch(suite_case, route_output)
  end

  @spec maybe_add_min_duration_mismatch([map()], map(), case_query_output()) :: [map()]
  defp maybe_add_min_duration_mismatch(
         mismatches,
         %{expected_min_duration_seconds: min_duration},
         _route_output
       )
       when not is_integer(min_duration),
       do: mismatches

  defp maybe_add_min_duration_mismatch(mismatches, suite_case, route_output) do
    duration = route_output.duration_seconds

    if is_number(duration) and duration >= suite_case.expected_min_duration_seconds do
      mismatches
    else
      [
        %{kind: :expected_min_duration_seconds, expected: suite_case.expected_min_duration_seconds, actual: duration}
        | mismatches
      ]
    end
  end

  @spec maybe_add_max_duration_mismatch([map()], map(), case_query_output()) :: [map()]
  defp maybe_add_max_duration_mismatch(
         mismatches,
         %{expected_max_duration_seconds: max_duration},
         _route_output
       )
       when not is_integer(max_duration),
       do: mismatches

  defp maybe_add_max_duration_mismatch(mismatches, suite_case, route_output) do
    duration = route_output.duration_seconds

    if is_number(duration) and duration <= suite_case.expected_max_duration_seconds do
      mismatches
    else
      [
        %{kind: :expected_max_duration_seconds, expected: suite_case.expected_max_duration_seconds, actual: duration}
        | mismatches
      ]
    end
  end

  @spec maybe_add_distance_mismatch([map()], map(), case_query_output()) :: [map()]
  defp maybe_add_distance_mismatch(mismatches, suite_case, route_output) do
    mismatches
    |> maybe_add_min_distance_mismatch(suite_case, route_output)
    |> maybe_add_max_distance_mismatch(suite_case, route_output)
  end

  @spec maybe_add_min_distance_mismatch([map()], map(), case_query_output()) :: [map()]
  defp maybe_add_min_distance_mismatch(
         mismatches,
         %{expected_min_distance_meters: min_distance},
         _route_output
       )
       when not is_integer(min_distance),
       do: mismatches

  defp maybe_add_min_distance_mismatch(mismatches, suite_case, route_output) do
    distance = route_output.distance_meters

    if is_number(distance) and distance >= suite_case.expected_min_distance_meters do
      mismatches
    else
      [
        %{kind: :expected_min_distance_meters, expected: suite_case.expected_min_distance_meters, actual: distance}
        | mismatches
      ]
    end
  end

  @spec maybe_add_max_distance_mismatch([map()], map(), case_query_output()) :: [map()]
  defp maybe_add_max_distance_mismatch(
         mismatches,
         %{expected_max_distance_meters: max_distance},
         _route_output
       )
       when not is_integer(max_distance),
       do: mismatches

  defp maybe_add_max_distance_mismatch(mismatches, suite_case, route_output) do
    distance = route_output.distance_meters

    if is_number(distance) and distance <= suite_case.expected_max_distance_meters do
      mismatches
    else
      [
        %{kind: :expected_max_distance_meters, expected: suite_case.expected_max_distance_meters, actual: distance}
        | mismatches
      ]
    end
  end

  @spec maybe_add_wheelchair_mismatch([map()], map(), case_query_output() | nil) :: [map()]
  defp maybe_add_wheelchair_mismatch(
         mismatches,
         %{expected_wheelchair_accessible: expected_wheelchair_accessible},
         _wheelchair_output
       )
       when expected_wheelchair_accessible not in [true, false],
       do: mismatches

  defp maybe_add_wheelchair_mismatch(mismatches, suite_case, nil) do
    [
      %{kind: :expected_wheelchair_accessible, expected: suite_case.expected_wheelchair_accessible, actual: nil}
      | mismatches
    ]
  end

  defp maybe_add_wheelchair_mismatch(mismatches, suite_case, wheelchair_output) do
    actual = wheelchair_output.route_exists

    if actual == suite_case.expected_wheelchair_accessible do
      mismatches
    else
      [
        %{kind: :expected_wheelchair_accessible, expected: suite_case.expected_wheelchair_accessible, actual: actual}
        | mismatches
      ]
    end
  end

  @spec summarize([map()]) :: run_summary()
  defp summarize(cases) do
    Enum.reduce(cases, empty_summary(), &update_summary_from_case/2)
  end

  @spec empty_summary() :: run_summary()
  defp empty_summary do
    %{total: 0, passed: 0, failed: 0, query_failure: 0, scoring_failure: 0}
  end

  @spec update_summary_from_case(map(), run_summary()) :: run_summary()
  defp update_summary_from_case(%{status: :passed}, acc) do
    %{acc | total: acc.total + 1, passed: acc.passed + 1}
  end

  defp update_summary_from_case(%{status: :failed, failure_category: :query_failure}, acc) do
    %{acc |
      total: acc.total + 1,
      failed: acc.failed + 1,
      query_failure: acc.query_failure + 1
    }
  end

  defp update_summary_from_case(%{status: :failed, failure_category: :scoring_failure}, acc) do
    %{acc |
      total: acc.total + 1,
      failed: acc.failed + 1,
      scoring_failure: acc.scoring_failure + 1
    }
  end

  defp update_summary_from_case(%{status: :failed}, acc) do
    %{acc | total: acc.total + 1, failed: acc.failed + 1}
  end

  @spec normalize_coordinate(term()) :: float() | nil
  defp normalize_coordinate(%Decimal{} = coordinate), do: Decimal.to_float(coordinate)
  defp normalize_coordinate(coordinate) when is_float(coordinate), do: coordinate
  defp normalize_coordinate(coordinate) when is_integer(coordinate), do: coordinate * 1.0
  defp normalize_coordinate(_coordinate), do: nil

  @spec emit_status((suite_progress_payload() -> any()) | nil, suite_progress_payload()) :: :ok
  defp emit_status(nil, _payload), do: :ok

  defp emit_status(status_callback, payload) when is_function(status_callback, 1) do
    status_callback.(payload)
    :ok
  end

  @spec build_destination_stops_by_stop_id(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) ::
          %{optional(String.t()) => Stop.t()}
  defp build_destination_stops_by_stop_id(organization_id, gtfs_version_id, selected_stop_ids) do
    selected_stop_ids_set = MapSet.new(selected_stop_ids)

    organization_id
    |> Gtfs.list_stops(gtfs_version_id)
    |> Enum.filter(fn %Stop{stop_id: stop_id} -> MapSet.member?(selected_stop_ids_set, stop_id) end)
    |> Map.new(fn %Stop{} = stop -> {stop.stop_id, stop} end)
  end
end
