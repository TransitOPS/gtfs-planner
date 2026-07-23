defmodule GtfsPlanner.Gtfs.FloorplanTransform do
  @moduledoc """
  Pure transform from floorplan SVG coordinate space to geographic
  latitude/longitude using saved alignment metadata.

  ## Coordinate conventions

  Diagram (SVG) coordinates are **width-normalized and top-left anchored**,
  matching the canvas they are authored in (`DiagramCanvas` renders the image
  with its width spanning the full 0–100 viewBox range, anchored top-left):
  one diagram unit is `image_w / 100` pixels on **both** axes, so a portrait
  image extends past `y = 100`.

  The alignment anchor (`center_lat`/`center_lon`) is the **painted image
  center** — pixel `(image_w / 2, image_h / 2)` — and `scale_mpp` is meters
  per natural image pixel, matching how `MapAlignmentHook._computeAlignment`
  defines them when an operator saves a manual alignment. `rotation_deg`
  rotates clockwise about that center.

  The transform is deterministic and has no Repo, Ecto, or LiveView
  dependencies.
  """

  @type alignment :: %{
          center_lat: float(),
          center_lon: float(),
          scale_mpp: float(),
          rotation_deg: float()
        }

  @type svg_point :: %{x: number(), y: number()}

  @type error_reason :: :invalid_alignment | :invalid_image_dims | :invalid_point

  @meters_per_degree_lat 111_111.0
  @cos_epsilon 1.0e-9

  @spec distance_meters({number(), number()}, {number(), number()}) :: float()
  def distance_meters({lat1, lon1}, {lat2, lon2}) do
    mean_lat_rad = deg_to_rad((lat1 + lat2) / 2.0)
    lat_m = (lat2 - lat1) * @meters_per_degree_lat
    lon_m = (lon2 - lon1) * @meters_per_degree_lat * :math.cos(mean_lat_rad)

    :math.sqrt(lat_m * lat_m + lon_m * lon_m)
  end

  @spec svg_to_lat_lon(alignment(), pos_integer(), pos_integer(), svg_point()) ::
          {:ok, {float(), float()}} | {:error, error_reason()}
  def svg_to_lat_lon(alignment, image_w, image_h, svg_point) do
    with {:ok, a} <- validate_alignment(alignment),
         :ok <- validate_image_dims(image_w, image_h),
         {:ok, point} <- validate_point(svg_point) do
      {:ok, project(a, image_w, image_h, point)}
    end
  end

  defp validate_alignment(%{} = alignment) do
    center_lat = Map.get(alignment, :center_lat)
    center_lon = Map.get(alignment, :center_lon)
    scale_mpp = Map.get(alignment, :scale_mpp)
    rotation_deg = Map.get(alignment, :rotation_deg)

    if is_number(center_lat) and is_number(center_lon) and
         is_number(scale_mpp) and is_number(rotation_deg) do
      cos_lat = :math.cos(deg_to_rad(center_lat))

      if abs(cos_lat) < @cos_epsilon do
        {:error, :invalid_alignment}
      else
        {:ok,
         %{
           center_lat: center_lat * 1.0,
           center_lon: center_lon * 1.0,
           scale_mpp: scale_mpp * 1.0,
           rotation_deg: rotation_deg * 1.0,
           cos_lat: cos_lat
         }}
      end
    else
      {:error, :invalid_alignment}
    end
  end

  defp validate_alignment(_), do: {:error, :invalid_alignment}

  defp validate_image_dims(w, h) when is_integer(w) and is_integer(h) and w > 0 and h > 0, do: :ok
  defp validate_image_dims(_, _), do: {:error, :invalid_image_dims}

  defp validate_point(%{} = point) do
    x = Map.get(point, :x)
    y = Map.get(point, :y)

    if is_number(x) and is_number(y) do
      {:ok, %{x: x * 1.0, y: y * 1.0}}
    else
      {:error, :invalid_point}
    end
  end

  defp validate_point(_), do: {:error, :invalid_point}

  defp project(a, image_w, image_h, point) do
    # One diagram unit is image_w / 100 px on BOTH axes (width-normalized,
    # top-left anchored — see the module doc), and the alignment anchor is the
    # painted image center, so offsets are taken from (image_w/2, image_h/2).
    unit = image_w / 100.0
    dx_img = point.x * unit - image_w / 2.0
    dy_img = point.y * unit - image_h / 2.0

    rotation_rad = deg_to_rad(a.rotation_deg)
    cos_r = :math.cos(rotation_rad)
    sin_r = :math.sin(rotation_rad)

    dx_screen = dx_img * cos_r - dy_img * sin_r
    dy_screen = dx_img * sin_r + dy_img * cos_r

    meters_east = dx_screen * a.scale_mpp
    meters_south = dy_screen * a.scale_mpp

    lat = a.center_lat - meters_south / @meters_per_degree_lat
    lon = a.center_lon + meters_east / (@meters_per_degree_lat * a.cos_lat)

    {lat, lon}
  end

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0
end
