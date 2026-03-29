defmodule GtfsPlanner.Validations.WalkabilitySuite do
  @moduledoc """
  Phase 4 walkability suite selector boundary.

  Selects a deterministic walkability suite for `(organization_id, gtfs_version_id)`
  and returns structured metadata for downstream runtime consumers.
  """

  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.WalkabilityTest
  alias GtfsPlanner.Gtfs

  @ordering "stop_id ASC, address ASC, id ASC"

  @type suite_case :: %{
          test_case_id: Ecto.UUID.t(),
          walkability_test_id: Ecto.UUID.t(),
          stop_id: String.t(),
          address: String.t(),
          address_lat: float(),
          address_lon: float(),
          expected_traversable: boolean() | nil,
          expected_wheelchair_accessible: boolean() | nil,
          expected_min_duration_seconds: integer() | nil,
          expected_max_duration_seconds: integer() | nil,
          expected_min_distance_meters: integer() | nil,
          expected_max_distance_meters: integer() | nil,
          description: String.t() | nil
        }

  @type invalid_case :: map()

  @type suite_meta :: %{
          total: non_neg_integer(),
          valid: non_neg_integer(),
          invalid: non_neg_integer(),
          ordering: String.t()
        }

  @type selection_details :: %{
          total_candidates: non_neg_integer(),
          in_scope_candidates: non_neg_integer(),
          selected_count: non_neg_integer(),
          invalid_count: non_neg_integer(),
          scope_label: String.t() | nil,
          selected_test_case_ids: [Ecto.UUID.t()],
          invalid_test_case_ids: [Ecto.UUID.t()],
          invalid_cases: [invalid_case()]
        }

  @type selection :: %{
          suite: [suite_case()],
          invalid_cases: [invalid_case()],
          meta: suite_meta(),
          selection: selection_details()
        }

  @spec select_suite(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: {:ok, selection()}
  def select_suite(organization_id, gtfs_version_id, opts \\ []) do
    valid_stop_ids =
      organization_id
      |> Gtfs.list_stops(gtfs_version_id)
      |> MapSet.new(& &1.stop_id)

    allowed_stop_ids =
      opts
      |> Keyword.get(:allowed_stop_ids)
      |> normalize_allowed_stop_ids()

    scope_label = normalize_scope_label(Keyword.get(opts, :scope_label))

    all_candidates = Validations.list_walkability_tests(organization_id, gtfs_version_id)

    in_scope_candidates =
      Enum.filter(all_candidates, fn %WalkabilityTest{stop_id: stop_id} ->
        in_scope_stop_id?(allowed_stop_ids, stop_id)
      end)

    {suite, invalid_cases} =
      in_scope_candidates
      |> Enum.map(&classify_row(&1, valid_stop_ids))
      |> Enum.reduce({[], []}, fn
        {:valid, suite_case}, {suite_acc, invalid_acc} ->
          {[suite_case | suite_acc], invalid_acc}

        {:invalid, invalid_case}, {suite_acc, invalid_acc} ->
          {suite_acc, [invalid_case | invalid_acc]}
      end)
      |> then(fn {suite_acc, invalid_acc} ->
        {Enum.reverse(suite_acc), Enum.reverse(invalid_acc)}
      end)

    total = length(in_scope_candidates)
    valid = length(suite)
    invalid = length(invalid_cases)

    selected_test_case_ids = Enum.map(suite, & &1.walkability_test_id)
    invalid_test_case_ids = Enum.map(invalid_cases, & &1.walkability_test_id)

    {:ok,
     %{
       suite: suite,
       invalid_cases: invalid_cases,
       meta: %{
         total: total,
         valid: valid,
         invalid: invalid,
         ordering: @ordering
       },
       selection: %{
         total_candidates: length(all_candidates),
         in_scope_candidates: length(in_scope_candidates),
         selected_count: valid,
         invalid_count: invalid,
         scope_label: scope_label,
         selected_test_case_ids: selected_test_case_ids,
         invalid_test_case_ids: invalid_test_case_ids,
         invalid_cases: invalid_cases
       }
     }}
  end

  defp normalize_scope_label(scope_label) when is_binary(scope_label) do
    scope_label = String.trim(scope_label)

    if scope_label == "" do
      nil
    else
      scope_label
    end
  end

  defp normalize_scope_label(_scope_label), do: nil

  defp normalize_allowed_stop_ids(nil), do: nil

  defp normalize_allowed_stop_ids(%MapSet{} = allowed_stop_ids), do: allowed_stop_ids

  defp normalize_allowed_stop_ids(allowed_stop_ids) when is_list(allowed_stop_ids),
    do: MapSet.new(allowed_stop_ids)

  defp in_scope_stop_id?(nil, _stop_id), do: true

  defp in_scope_stop_id?(%MapSet{} = allowed_stop_ids, stop_id),
    do: MapSet.member?(allowed_stop_ids, stop_id)

  defp classify_row(%WalkabilityTest{} = walkability_test, valid_stop_ids) do
    case malformed_reason(walkability_test, valid_stop_ids) do
      nil -> {:valid, to_suite_case(walkability_test)}
      reason -> {:invalid, to_invalid_case(walkability_test, reason)}
    end
  end

  defp malformed_reason(%WalkabilityTest{address_lat: nil}, _valid_stop_ids),
    do: :missing_coordinates

  defp malformed_reason(%WalkabilityTest{address_lon: nil}, _valid_stop_ids),
    do: :missing_coordinates

  defp malformed_reason(%WalkabilityTest{} = walkability_test, valid_stop_ids) do
    cond do
      invalid_coordinate_range?(walkability_test) ->
        :invalid_coordinate_range

      invalid_stop_id_for_version?(walkability_test, valid_stop_ids) ->
        :invalid_stop_id_for_version

      invalid_expectation_bounds?(walkability_test) ->
        :invalid_expectation_bounds

      true ->
        nil
    end
  end

  defp invalid_stop_id_for_version?(
         %WalkabilityTest{stop_id: stop_id},
         valid_stop_ids
       ) do
    not MapSet.member?(valid_stop_ids, stop_id)
  end

  defp invalid_coordinate_range?(%WalkabilityTest{address_lat: lat, address_lon: lon}) do
    not coordinate_in_range?(lat, -90.0, 90.0) or
      not coordinate_in_range?(lon, -180.0, 180.0)
  end

  defp invalid_expectation_bounds?(%WalkabilityTest{} = walkability_test) do
    not expectation_bounds_valid?(
      walkability_test.expected_min_duration_seconds,
      walkability_test.expected_max_duration_seconds
    ) or
      not expectation_bounds_valid?(
        walkability_test.expected_min_distance_meters,
        walkability_test.expected_max_distance_meters
      )
  end

  defp to_invalid_case(%WalkabilityTest{} = walkability_test, reason) do
    %{
      test_case_id: walkability_test.id,
      walkability_test_id: walkability_test.id,
      reason_code: reason,
      stop_id: walkability_test.stop_id,
      address: walkability_test.address
    }
  end

  defp coordinate_in_range?(%Decimal{} = value, min, max) do
    value
    |> Decimal.to_float()
    |> coordinate_in_range?(min, max)
  end

  defp coordinate_in_range?(value, min, max) when is_float(value),
    do: value >= min and value <= max

  defp coordinate_in_range?(value, min, max) when is_integer(value),
    do: value >= min and value <= max

  defp coordinate_in_range?(_, _, _), do: false

  defp expectation_bounds_valid?(nil, nil), do: true
  defp expectation_bounds_valid?(nil, _max), do: true
  defp expectation_bounds_valid?(_min, nil), do: true

  defp expectation_bounds_valid?(min, max)
       when is_integer(min) and is_integer(max) and min <= max,
       do: true

  defp expectation_bounds_valid?(_, _), do: false

  @spec to_suite_case(WalkabilityTest.t()) :: suite_case()
  defp to_suite_case(%WalkabilityTest{} = walkability_test) do
    %{
      test_case_id: walkability_test.id,
      walkability_test_id: walkability_test.id,
      stop_id: walkability_test.stop_id,
      address: walkability_test.address,
      address_lat: normalize_coordinate(walkability_test.address_lat),
      address_lon: normalize_coordinate(walkability_test.address_lon),
      expected_traversable: normalize_optional_boolean(walkability_test.expected_traversable),
      expected_wheelchair_accessible:
        normalize_optional_boolean(walkability_test.expected_wheelchair_accessible),
      expected_min_duration_seconds:
        normalize_optional_integer(walkability_test.expected_min_duration_seconds),
      expected_max_duration_seconds:
        normalize_optional_integer(walkability_test.expected_max_duration_seconds),
      expected_min_distance_meters:
        normalize_optional_integer(walkability_test.expected_min_distance_meters),
      expected_max_distance_meters:
        normalize_optional_integer(walkability_test.expected_max_distance_meters),
      description: walkability_test.description
    }
  end

  defp normalize_coordinate(%Decimal{} = coordinate), do: Decimal.to_float(coordinate)

  defp normalize_optional_boolean(value) when value in [true, false], do: value
  defp normalize_optional_boolean(_), do: nil

  defp normalize_optional_integer(value) when is_integer(value), do: value
  defp normalize_optional_integer(_), do: nil
end
