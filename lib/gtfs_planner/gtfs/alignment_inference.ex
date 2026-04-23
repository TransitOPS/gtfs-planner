defmodule GtfsPlanner.Gtfs.AlignmentInference do
  @moduledoc """
  Pure inference of floorplan alignment from anchored stops.

  Solves a 2D similarity transform (uniform scale, rotation, translation)
  that maps SVG percentage coordinates (0-100) to local meter offsets
  derived from anchor latitude/longitude, then reconstructs the four
  alignment fields consumed by `GtfsPlanner.Gtfs.FloorplanTransform`.

  No Ecto, Repo, or LiveView dependencies.
  """

  @type anchor :: %{
          stop_id: String.t(),
          source: :direct | :cross_level,
          svg_x: float(),
          svg_y: float(),
          lat: float(),
          lon: float()
        }

  @type inferred_alignment :: %{
          center_lat: float(),
          center_lon: float(),
          scale_mpp: float(),
          rotation_deg: float(),
          rmse_meters: float(),
          anchor_count: non_neg_integer()
        }

  @type error_reason ::
          :insufficient_anchors
          | :degenerate_geometry
          | :high_residual
          | :invalid_input

  @max_rmse_meters 2.0
  @meters_per_degree_lat 111_111.0
  @degenerate_epsilon 1.0e-6

  @spec infer_alignment([anchor()], pos_integer(), pos_integer()) ::
          {:ok, inferred_alignment()} | {:error, error_reason()}
  def infer_alignment(anchors, image_w, image_h) do
    with :ok <- validate_dims(image_w, image_h),
         {:ok, validated} <- validate_anchors(anchors),
         :ok <- check_count(validated),
         {:ok, solution} <- solve(validated, image_w, image_h),
         :ok <- check_residual(solution) do
      {:ok, to_alignment(solution)}
    end
  end

  defp validate_dims(w, h) when is_integer(w) and is_integer(h) and w > 0 and h > 0, do: :ok
  defp validate_dims(_, _), do: {:error, :invalid_input}

  defp validate_anchors(anchors) when is_list(anchors) do
    Enum.reduce_while(anchors, {:ok, []}, fn anchor, {:ok, acc} ->
      case validate_anchor(anchor) do
        {:ok, a} -> {:cont, {:ok, [a | acc]}}
        :error -> {:halt, {:error, :invalid_input}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp validate_anchors(_), do: {:error, :invalid_input}

  defp validate_anchor(%{svg_x: sx, svg_y: sy, lat: lat, lon: lon} = anchor) do
    if is_number(sx) and is_number(sy) and is_number(lat) and is_number(lon) do
      {:ok, %{anchor | svg_x: sx * 1.0, svg_y: sy * 1.0, lat: lat * 1.0, lon: lon * 1.0}}
    else
      :error
    end
  end

  defp validate_anchor(_), do: :error

  defp check_count(anchors) when length(anchors) >= 2, do: :ok
  defp check_count(_), do: {:error, :insufficient_anchors}

  defp solve(anchors, image_w, image_h) do
    fit = max(image_w, image_h) / 100.0
    lat0 = mean(Enum.map(anchors, & &1.lat))
    lon0 = mean(Enum.map(anchors, & &1.lon))

    with {:ok, first} <- solve_pass(anchors, fit, lat0, lon0, :math.cos(deg_to_rad(lat0))),
         refined_center_lat <- lat0 - first.transform.ty / @meters_per_degree_lat,
         {:ok, solution} <-
           solve_pass(anchors, fit, lat0, lon0, :math.cos(deg_to_rad(refined_center_lat))) do
      {:ok, Map.put(solution, :anchor_count, length(anchors))}
    end
  end

  defp solve_pass(anchors, fit, lat0, lon0, cos_lat) do
    pq =
      Enum.map(anchors, fn a ->
        p = {(a.svg_x - 50.0) * fit, (a.svg_y - 50.0) * fit}
        east = (a.lon - lon0) * @meters_per_degree_lat * cos_lat
        south = -(a.lat - lat0) * @meters_per_degree_lat
        {p, {east, south}}
      end)

    with :ok <- check_degenerate(pq),
         {:ok, transform} <- fit_similarity(pq) do
      rmse = rmse_meters(pq, transform)

      {:ok,
       %{
         transform: transform,
         lat0: lat0,
         lon0: lon0,
         cos_lat0: cos_lat,
         rmse: rmse
       }}
    end
  end

  defp check_degenerate(pq) do
    ps = Enum.map(pq, fn {p, _} -> p end)
    {pxs, pys} = Enum.unzip(ps)
    spread = spread_sum(pxs, pys)

    if spread < @degenerate_epsilon do
      {:error, :degenerate_geometry}
    else
      :ok
    end
  end

  defp spread_sum(xs, ys) do
    mx = mean(xs)
    my = mean(ys)

    xs
    |> Enum.zip(ys)
    |> Enum.reduce(0.0, fn {x, y}, acc -> acc + (x - mx) * (x - mx) + (y - my) * (y - my) end)
  end

  defp fit_similarity(pq) do
    {pxs, pys} = pq |> Enum.map(fn {p, _} -> p end) |> Enum.unzip()
    {exs, sys} = pq |> Enum.map(fn {_, q} -> q end) |> Enum.unzip()

    pxm = mean(pxs)
    pym = mean(pys)
    exm = mean(exs)
    sym = mean(sys)

    {num_a, num_b, den} =
      pq
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {{px, py}, {east, south}}, {na, nb, d} ->
        dx = px - pxm
        dy = py - pym
        de = east - exm
        ds = south - sym
        {na + dx * de + dy * ds, nb + dx * ds - dy * de, d + dx * dx + dy * dy}
      end)

    if den < @degenerate_epsilon do
      {:error, :degenerate_geometry}
    else
      a = num_a / den
      b = num_b / den
      tx = exm - (a * pxm - b * pym)
      ty = sym - (b * pxm + a * pym)
      {:ok, %{a: a, b: b, tx: tx, ty: ty}}
    end
  end

  defp rmse_meters(pq, %{a: a, b: b, tx: tx, ty: ty}) do
    {sum_sq, n} =
      Enum.reduce(pq, {0.0, 0}, fn {{px, py}, {east, south}}, {acc, count} ->
        pred_e = a * px - b * py + tx
        pred_s = b * px + a * py + ty
        d = (pred_e - east) * (pred_e - east) + (pred_s - south) * (pred_s - south)
        {acc + d, count + 1}
      end)

    if n <= 2, do: 0.0, else: :math.sqrt(sum_sq / n)
  end

  defp check_residual(%{rmse: rmse}) when rmse > @max_rmse_meters, do: {:error, :high_residual}
  defp check_residual(_), do: :ok

  defp to_alignment(%{transform: t, lat0: lat0, lon0: lon0, cos_lat0: cos_lat0} = sol) do
    scale = :math.sqrt(t.a * t.a + t.b * t.b)
    rotation_deg = rad_to_deg(:math.atan2(t.b, t.a))
    center_lat = lat0 - t.ty / @meters_per_degree_lat
    center_lon = lon0 + t.tx / (@meters_per_degree_lat * cos_lat0)

    %{
      center_lat: center_lat,
      center_lon: center_lon,
      scale_mpp: scale,
      rotation_deg: rotation_deg,
      rmse_meters: sol.rmse,
      anchor_count: sol.anchor_count
    }
  end

  defp mean([]), do: 0.0
  defp mean(list), do: Enum.sum(list) / length(list)

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0
  defp rad_to_deg(rad), do: rad * 180.0 / :math.pi()
end
