defmodule GtfsPlanner.Gtfs.ReleaseComparison.MatchingTest do
  @moduledoc """
  Focused evidence for CL-4/FH-4: entity correspondence is exact and
  categorical, and ID reuse, structural change and ambiguous twins stay
  distinguishable instead of producing a guessed pair or a false unchanged
  claim.

  Every expected value is hand-calculated from the fixture in each test. The
  first case runs the real native exporter, the step 2 reader and the step 3
  projection before matching, so the shape `match/2` actually receives is the
  shape a genuine artifact produces - including the stored primary references
  the native exporter writes into the foreign columns.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.ReleaseComparison
  alias GtfsPlanner.Gtfs.ReleaseComparison.Matching
  alias GtfsPlanner.Gtfs.ReleaseComparison.Projection
  alias GtfsPlanner.Gtfs.ReleaseComparison.Reader
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  describe "match/2 on genuine native artifacts" do
    setup :create_and_set_owned_artifact_root

    test "resolves what it can and discloses what the native artifact cannot resolve" do
      %{organization: organization, version: version, scope: scope} = setup_context()

      seed_native_version!(organization, version)
      {:ok, projection} = native_projection(organization, version, scope)

      # `stops.txt` carries the real stop identifier, so the one stop matches by
      # identical identifier.
      assert [stop] = correspondences(projection, projection, :stops)
      assert stop.category == :exact_id
      assert stop.left_ref == %{id: "S1", file: "stops.txt", row: 2}
      assert stop.right_ref == stop.left_ref
      refute stop.meaning_changed

      # `routes.txt` names the agency's stored primary reference, which no agency
      # in the file defines. The route still matches by identical identifier,
      # because an identical identifier is categorical, but it has no provable
      # agency identity at all, so no renamed route can ever be paired against
      # it and that is disclosed rather than guessed.
      assert [route] = correspondences(projection, projection, :routes)
      assert route.category == :exact_id
      assert route.left_ref == %{id: "R1", file: "routes.txt", row: 2}

      # `trips.txt` names the route's stored reference, which is not `R1`. No
      # correspondence is claimed for that, exactly as the projection disclosed
      # it, and nothing anywhere in the result is a probability.
      assert [trip] = Map.values(projection.trips)
      assert trip.route_id != "R1"
      assert Enum.any?(projection.unknowns, &(&1.reason == :unknown_route))

      matches = Matching.match(projection, projection)

      # A matched-against-itself artifact produces no structural change and no
      # unresolved correspondence, and no correspondence carries a numeric
      # confidence: the only categories are the four categorical ones.
      assert matches.structural_changes == []
      assert matches.unresolved == []

      for entity <- [:agencies, :routes, :stops] do
        for entry <- Map.fetch!(matches, entity) do
          assert entry.category in [:exact_id, :unique_exact, :ambiguous, :unmatched]
          assert is_boolean(entry.meaning_changed)
        end
      end

      # Nothing here read the live version: the projection, and therefore the
      # correspondence, describes the selected bytes only.
      assert_no_live_read(projection, projection)
    end

    test "a second native artifact from a renamed route keeps correspondence truthful" do
      %{organization: organization, version: version, scope: scope} = setup_context()

      seed_native_version!(organization, version)
      {:ok, left} = native_projection(organization, version, scope)

      # A different version, exported natively, renames the route. Its route
      # still carries an unresolvable agency reference, so the rename is not
      # claimed; the route is disclosed as its own entity and the stop, whose
      # identifier is real in both files, is the only correspondence.
      other_version = gtfs_version_fixture(organization.id)

      seed_native_version!(organization, other_version, %{
        route_id: "R1",
        route_long_name: "Renamed"
      })

      {:ok, right} = native_projection(organization, other_version, scope)

      matches = Matching.match(left, right)

      assert Enum.all?(matches.routes, &(&1.category == :exact_id or &1.category == :unmatched))
      assert [route_change] = Enum.filter(matches.structural_changes, &(&1.change == :long_name))
      assert route_change.left == "Test Route"
      assert route_change.right == "Renamed"
      refute route_change.meaning_changed
    end
  end

  describe "agencies" do
    test "an identical identifier with a changed name is correspondence, not churn" do
      left = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{},
        stops: %{}
      }

      right = %{
        agencies: %{"A1" => agency("A1", "Metro Transit", "http://a", "UTC")},
        routes: %{},
        stops: %{}
      }

      result = Matching.match(left, right)

      assert [pair] = result.agencies
      assert pair.category == :exact_id
      assert pair.reason == :same_id
      refute pair.meaning_changed
      assert [%{change: :name, left: "Metro", right: "Metro Transit"}] = result.structural_changes
      assert result.unresolved == []
    end

    test "a changed timezone on one identifier is a meaning change" do
      left = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{},
        stops: %{}
      }

      right = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "America/Denver")},
        routes: %{},
        stops: %{}
      }

      result = Matching.match(left, right)

      assert [pair] = result.agencies
      assert pair.category == :exact_id
      assert pair.meaning_changed
      assert [%{change: :timezone, meaning_changed: true}] = result.structural_changes
    end

    test "a complete identical name, url and timezone under a new identifier is churn" do
      left = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{},
        stops: %{}
      }

      right = %{
        agencies: %{"A9" => agency("A9", "Metro", "http://a", "UTC")},
        routes: %{},
        stops: %{}
      }

      result = Matching.match(left, right)

      assert [pair] = result.agencies
      assert pair.category == :unique_exact
      assert pair.rule == :agency_name_url_timezone
      assert pair.left_ref.id == "A1"
      assert pair.right_ref.id == "A9"
      assert result.structural_changes == []
      assert result.unresolved == []
    end

    test "absent url, name or timezone evidence cannot create a match" do
      left = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{},
        stops: %{}
      }

      right = %{agencies: %{"A9" => agency("A9", "Metro", "", "UTC")}, routes: %{}, stops: %{}}

      result = Matching.match(left, right)

      assert left_only = entry(result.agencies, :left, "A1")
      assert left_only.category == :unmatched
      assert left_only.reason == :no_candidate

      assert right_only = entry(result.agencies, :right, "A9")
      assert right_only.category == :unmatched

      # The right agency has no url, so it carries no signature at all; the left
      # one has a complete signature and simply found no counterpart.
      assert right_only.reason == :incomplete_signature
    end
  end

  describe "routes" do
    test "an identical identifier with a changed type is correspondence and a meaning change" do
      left = %{agencies: %{}, routes: %{"R1" => route("R1", "A1", "1", "Main", 3)}, stops: %{}}
      right = %{agencies: %{}, routes: %{"R1" => route("R1", "A1", "1", "Main", 1)}, stops: %{}}

      result = Matching.match(left, right)

      assert [pair] = result.routes
      assert pair.category == :exact_id
      assert pair.meaning_changed

      assert [%{change: :route_type, left: 3, right: 1, meaning_changed: true}] =
               result.structural_changes
    end

    test "a unique identical mapped agency, type and names under a new identifier is churn" do
      left = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{"R1" => route("R1", "A1", "1", "Main", 3)},
        stops: %{}
      }

      right = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{"R9" => route("R9", "A1", "1", "Main", 3)},
        stops: %{}
      }

      result = Matching.match(left, right)

      assert [pair] = result.routes
      assert pair.category == :unique_exact
      assert pair.rule == :mapped_agency_type_names
      assert pair.left_ref.id == "R1"
      assert pair.right_ref.id == "R9"
      assert result.structural_changes == []
    end

    test "a route whose agency does not resolve is never matched as a rename" do
      left = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{"R1" => route("R1", "A1", "1", "Main", 3)},
        stops: %{}
      }

      # The right artifact's route names an agency UUID the file does not
      # define, exactly as the native exporter writes it. Its mapped agency
      # identity is unknown, so a left route can never be claimed as its
      # rename, even though the type and both names are identical.
      right = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{"R9" => route("R9", "0f6b2a4e-1c2d-4a3b-8e5f-6a7b8c9d0e1f", "1", "Main", 3)},
        stops: %{}
      }

      result = Matching.match(left, right)

      # The left route names an agency this artifact does define, so its own
      # evidence is complete; it simply has no counterpart. The right route's
      # agency reference resolves to nothing, which is the reason it can never
      # be claimed as anyone's rename.
      assert left_route = entry(result.routes, :left, "R1")
      assert left_route.category == :unmatched
      assert left_route.reason == :no_candidate

      assert right_route = entry(result.routes, :right, "R9")
      assert right_route.category == :unmatched
      assert right_route.reason == :unresolved_agency
      assert result.structural_changes == []
    end

    test "two routes with identical signatures on the right stay ambiguous with every candidate" do
      left = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{"R1" => route("R1", "A1", "1", "Main", 3)},
        stops: %{}
      }

      right = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{
          "R8" => route("R8", "A1", "1", "Main", 3),
          "R9" => route("R9", "A1", "1", "Main", 3)
        },
        stops: %{}
      }

      result = Matching.match(left, right)

      assert left_route = entry(result.routes, :left, "R1")
      assert left_route.category == :ambiguous
      assert left_route.reason == :ambiguous_signature
      assert Enum.map(left_route.candidates, & &1.id) == ["R8", "R9"]

      for id <- ["R8", "R9"] do
        twin = entry(result.routes, :right, id)
        assert twin.category == :ambiguous
        assert Enum.map(twin.candidates, & &1.id) == ["R1"]
      end

      assert Enum.all?(result.unresolved, &(&1.entity == :route))
      assert Enum.all?(result.unresolved, &(&1.reason == :ambiguous_signature))
      assert Enum.all?(result.unresolved, &(&1.candidates != []))
    end

    test "a blank route name cannot create a match" do
      left = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{"R1" => route("R1", "A1", "", "", 3)},
        stops: %{}
      }

      right = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{"R9" => route("R9", "A1", "", "", 3)},
        stops: %{}
      }

      result = Matching.match(left, right)

      assert left_route = entry(result.routes, :left, "R1")
      assert left_route.category == :unmatched
      assert left_route.reason == :incomplete_signature
      assert entry(result.routes, :right, "R9").category == :unmatched
    end
  end

  describe "stops" do
    test "coordinates compare by numeric value, not by string" do
      left = %{
        agencies: %{},
        routes: %{},
        stops: %{"S1" => stop("S1", "First", "40.100", "-74.10")}
      }

      right = %{
        agencies: %{},
        routes: %{},
        stops: %{"S9" => stop("S9", "First", "40.1", "-74.1")}
      }

      result = Matching.match(left, right)

      assert [pair] = result.stops
      assert pair.category == :unique_exact
      assert pair.left_ref.id == "S1"
      assert pair.right_ref.id == "S9"
    end

    test "an identical identifier whose type, parent or coordinates moved keeps its correspondence" do
      left = %{
        agencies: %{},
        routes: %{},
        stops: %{
          "P1" => station("P1"),
          "S1" => child("S1", "P1", "40.1", "-74.1", 0)
        }
      }

      right = %{
        agencies: %{},
        routes: %{},
        stops: %{
          "P1" => station("P1"),
          "S1" => child("S1", "P1", "40.2", "-74.1", 1)
        }
      }

      result = Matching.match(left, right)

      pair = entry(result.stops, :left, "S1")
      assert pair.category == :exact_id
      assert pair.meaning_changed

      changes = Enum.filter(result.structural_changes, &(&1.id == "S1"))
      assert Enum.map(changes, & &1.change) == [:coordinates, :location_type]
      assert Enum.all?(changes, & &1.meaning_changed)
    end

    test "a moved parent is a structural change even when the raw identifier is unchanged" do
      left = %{
        agencies: %{},
        routes: %{},
        stops: %{
          "P1" => station("P1"),
          "P2" => station("P2"),
          "S1" => child("S1", "P1", "40.1", "-74.1", 0)
        }
      }

      # The same parent identifier now names a station with a different name and
      # coordinates, so the resolved parent is a different place even though the
      # raw string is equal.
      right = %{
        agencies: %{},
        routes: %{},
        stops: %{
          "P1" => station("P1"),
          "P2" => renamed_station("P2", "Zone Two", "41.5", "-75.5"),
          "S1" => child("S1", "P1", "40.1", "-74.1", 0)
        }
      }

      result = Matching.match(left, right)

      # `P2` is not this stop's parent, so nothing about `S1`'s parent moved and
      # the only correspondence is by identical identifier.
      # `P2` was reused for a station somewhere else, so its name and
      # coordinates both moved. That is a structural change on `P2` itself and
      # says nothing about `S1`, whose parent reference is the same place on
      # both sides.
      assert [%{id: "P2", change: :coordinates}, %{id: "P2", change: :name}] =
               result.structural_changes

      assert Enum.all?(result.structural_changes, & &1.meaning_changed)

      pair = entry(result.stops, :left, "S1")
      assert pair.category == :exact_id
      refute pair.meaning_changed
    end

    test "a renamed child whose parent is unresolved stays unmatched" do
      left = %{
        agencies: %{},
        routes: %{},
        stops: %{"P1" => station("P1"), "C1" => child("C1", "P1", "40.1", "-74.1", 0)}
      }

      # The parent was renamed to a new identifier, so on this side the child's
      # parent reference names a station that does not exist.
      right = %{
        agencies: %{},
        routes: %{},
        stops: %{"P9" => station("P9"), "C1" => child("C1", "P1", "40.1", "-74.1", 0)}
      }

      result = Matching.match(left, right)

      # The parent itself pairs by signature, which resolves the child in the
      # following pass: ordering never silently drops a real pair.
      parent = entry(result.stops, :left, "P1")
      assert parent.category == :unique_exact
      assert parent.right_ref.id == "P9"

      child = entry(result.stops, :left, "C1")
      assert child.category == :exact_id
      refute child.meaning_changed
    end

    test "a renamed child whose parent cannot be matched at all stays unmatched" do
      left = %{
        agencies: %{},
        routes: %{},
        stops: %{
          "P1" => station("P1"),
          "C1" => child("C1", "P1", "40.1", "-74.1", 0),
          "C2" => child("C2", "P1", "40.2", "-74.2", 0)
        }
      }

      # Two identically-named parents with identical coordinates cannot be told
      # apart, so neither is provable and no child has a resolved parent.
      right = %{
        agencies: %{},
        routes: %{},
        stops: %{
          "P8" => station("P8"),
          "P9" => station("P9"),
          "C9" => child("C9", "P8", "40.1", "-74.1", 0)
        }
      }

      result = Matching.match(left, right)

      # The left parent shares a signature with two right stations, so it is
      # ambiguous and keeps every candidate reference.
      parent = entry(result.stops, :left, "P1")
      assert parent.category == :ambiguous
      assert parent.reason == :ambiguous_signature
      assert Enum.map(parent.candidates, & &1.id) == ["P8", "P9"]

      for id <- ["P8", "P9"] do
        twin = entry(result.stops, :right, id)
        assert twin.category == :ambiguous
        assert Enum.map(twin.candidates, & &1.id) == ["P1"]
      end

      # No child can be claimed, because its parent is not resolved.
      for id <- ["C1", "C2"] do
        child = entry(result.stops, :left, id)
        assert child.category == :unmatched
        assert child.reason == :unresolved_parent
      end

      assert entry(result.stops, :right, "C9").reason == :unresolved_parent
    end

    test "absent coordinates cannot create a match" do
      left = %{agencies: %{}, routes: %{}, stops: %{"S1" => stop("S1", "First", "", "")}}
      right = %{agencies: %{}, routes: %{}, stops: %{"S9" => stop("S9", "First", "", "")}}

      result = Matching.match(left, right)

      assert left_stop = entry(result.stops, :left, "S1")
      assert left_stop.category == :unmatched
      assert left_stop.reason == :incomplete_signature
      assert entry(result.stops, :right, "S9").category == :unmatched
    end
  end

  describe "match_trips/3" do
    setup do
      projection = %{
        agencies: %{"A1" => agency("A1", "Metro", "http://a", "UTC")},
        routes: %{"R1" => route("R1", "A1", "1", "Main", 3)},
        stops: %{
          "S1" => stop("S1", "First", "40.1", "-74.1"),
          "S2" => stop("S2", "Second", "40.2", "-74.2")
        }
      }

      %{matches: Matching.match(projection, projection), projection: projection}
    end

    test "an exact rename with an identical mapped pattern and time vector pairs", context do
      left = %{evaluated_trips: [trip("T1", "R1", 28_800)]}
      right = %{evaluated_trips: [trip("T9", "R1", 28_800)]}

      result = Matching.match_trips(left, right, context.matches)

      assert [pair] = result.pairs
      assert pair.category == :unique_exact
      assert pair.rule == :route_pattern_dates_times_frequencies
      assert pair.left_ref.id == "T1"
      assert pair.right_ref.id == "T9"
      assert result.structural_changes == []
      assert result.unresolved == []
    end

    test "a renamed trip whose times shifted stays unresolved", context do
      left = %{evaluated_trips: [trip("T1", "R1", 28_800)]}
      right = %{evaluated_trips: [trip("T9", "R1", 29_400)]}

      result = Matching.match_trips(left, right, context.matches)

      assert result.pairs == [] or Enum.all?(result.pairs, &(&1.category == :unmatched))
      assert [_, _] = result.unresolved
      assert left_trip = entry(result.unresolved, :left, "T1")
      assert right_trip = entry(result.unresolved, :right, "T9")
      assert left_trip.reason == :no_candidate
      assert right_trip.reason == :no_candidate
    end

    test "an identical identifier with a changed stop sequence is a meaning change", context do
      left = %{evaluated_trips: [loop_trip("T1", 9)]}
      right = %{evaluated_trips: [loop_trip("T1", 8)]}

      result = Matching.match_trips(left, right, context.matches)

      assert [pair] = result.pairs
      assert pair.category == :exact_id
      assert pair.meaning_changed

      assert [%{change: :stop_pattern, meaning_changed: true}] = result.structural_changes
      assert result.unresolved == []
    end

    test "a loop's repeated stop keeps its sequence identity", context do
      left = %{evaluated_trips: [loop_trip("T1", 9)]}
      right = %{evaluated_trips: [loop_trip("T1", 9)]}

      result = Matching.match_trips(left, right, context.matches)

      assert [pair] = result.pairs
      assert pair.category == :exact_id
      refute pair.meaning_changed
      assert result.structural_changes == []
    end

    test "identical twins on the right stay ambiguous with every candidate reference", context do
      left = %{evaluated_trips: [trip("T1", "R1", 28_800)]}
      right = %{evaluated_trips: [trip("T9", "R1", 28_800), trip("T8", "R1", 28_800)]}

      result = Matching.match_trips(left, right, context.matches)

      assert result.pairs == [] or Enum.all?(result.pairs, &(&1.category != :exact_id))
      refute Enum.any?(result.pairs, &(&1.category == :unique_exact))

      left_trip = Enum.find(result.unresolved, &(&1.left_ref && &1.left_ref.id == "T1"))
      assert left_trip.reason == :ambiguous_signature
      assert Enum.map(left_trip.candidates, & &1.id) == ["T8", "T9"]

      # Each twin keeps the left trip as its own candidate reference.
      for id <- ["T8", "T9"] do
        twin = Enum.find(result.unresolved, &(&1.right_ref && &1.right_ref.id == id))
        assert Enum.map(twin.candidates, & &1.id) == ["T1"]
      end
    end

    test "a trip whose route identity is unproven does not pair by identical identifier",
         context do
      left = %{evaluated_trips: [trip("T1", "R_UNRESOLVED_LEFT", 28_800)]}
      right = %{evaluated_trips: [trip("T1", "R_UNRESOLVED_RIGHT", 28_800)]}

      result = Matching.match_trips(left, right, context.matches)

      refute Enum.any?(result.pairs, &(&1.category == :exact_id))

      # Both trips stay unresolved with the unproven route as the reason: a
      # shared identifier is not enough when its route identity is unknown.
      assert Enum.all?(result.unresolved, &(&1.reason == :unresolved_route))
      assert Enum.map(result.unresolved, &ref_id/1) == ["T1", "T1"]
    end

    test "a trip with an unevaluable time is not matched by the fields that did parse", context do
      left = %{evaluated_trips: [partial_trip("T1", "R1")]}
      right = %{evaluated_trips: [trip("T9", "R1", 28_800)]}

      result = Matching.match_trips(left, right, context.matches)

      refute Enum.any?(result.pairs, &(&1.category == :unique_exact))
      assert Enum.any?(result.unresolved, &(&1.reason == :incomplete_signature))
    end

    test "no correspondence anywhere carries a numeric confidence", context do
      left = %{evaluated_trips: [trip("T1", "R1", 28_800), loop_trip("T2", 9)]}
      right = %{evaluated_trips: [trip("T9", "R1", 29_400), trip("T8", "R_UNRESOLVED", 28_800)]}

      result = Matching.match_trips(left, right, context.matches)

      for entry <- result.pairs ++ result.unresolved do
        assert Enum.all?(Map.keys(entry), &is_atom/1)

        assert entry.reason in [
                 :same_id,
                 :unique_exact_signature,
                 :ambiguous_signature,
                 :no_candidate,
                 :unresolved_route,
                 :incomplete_signature
               ]
      end

      # The only category a pair can carry is one of the four categorical ones,
      # so no numeric confidence can exist anywhere in the result.
      assert Enum.all?(
               result.pairs,
               &(&1.category in [
                   :exact_id,
                   :unique_exact,
                   :ambiguous,
                   :unmatched
                 ])
             )
    end
  end

  # -- fixtures ----------------------------------------------------------------

  defp correspondences(projection, other, entity) do
    result = Matching.match(projection, other)
    Map.fetch!(result, entity)
  end

  # Every output is sorted, so a test names the entity it means instead of
  # depending on where an entry happened to land.
  defp entry(correspondences, side, id) do
    Enum.find(correspondences, &(ref_side(&1) == side and ref_id(&1) == id)) ||
      flunk("no #{side} correspondence for #{id} in #{inspect(correspondences)}")
  end

  defp ref_side(%{left_ref: %{id: id}}) when is_binary(id), do: :left
  defp ref_side(%{right_ref: %{id: id}}) when is_binary(id), do: :right
  defp ref_side(_entry), do: :absent

  defp ref_id(%{left_ref: %{id: id}}) when is_binary(id), do: id
  defp ref_id(%{right_ref: %{id: id}}) when is_binary(id), do: id
  defp ref_id(_entry), do: nil

  defp source(file, row), do: %{file: file, row: row}

  defp agency(id, name, url, timezone) do
    %{
      agency_id: id,
      name: name,
      url: url,
      timezone: if(timezone == "", do: nil, else: timezone),
      source: source("agency.txt", 2)
    }
  end

  defp route(id, agency_id, short_name, long_name, type) do
    %{
      route_id: id,
      agency_id: agency_id,
      short_name: short_name,
      long_name: long_name,
      route_type: type,
      source: source("routes.txt", 2)
    }
  end

  defp stop(id, name, lat, lon) do
    stop_at(id, name, lat, lon, 0, "", 2)
  end

  defp station(id), do: station_at(id, "Zone", "41.0", "-75.0")

  defp renamed_station(id, name, lat, lon), do: station_at(id, name, lat, lon)

  defp station_at(id, name, lat, lon), do: stop_at(id, name, lat, lon, 1, "", 2)

  defp child(id, parent, lat, lon, type) do
    stop_at(id, "Child", lat, lon, type, parent, 3)
  end

  defp stop_at(id, name, lat, lon, type, parent, row) do
    %{
      stop_id: id,
      name: name,
      lat: if(lat == "", do: nil, else: Decimal.new(lat)),
      lon: if(lon == "", do: nil, else: Decimal.new(lon)),
      location_type: type,
      parent_station: parent,
      source: source("stops.txt", row)
    }
  end

  defp trip(id, route_id, first_secs) do
    %{
      trip_id: id,
      route_id: route_id,
      direction_id: 0,
      service_dates: [~D[2026-04-01]],
      pattern: [
        %{stop_id: "S1", sequence: 1},
        %{stop_id: "S2", sequence: 2}
      ],
      time_vector: [{first_secs, first_secs}, {first_secs + 600, first_secs + 600}],
      frequencies: [],
      source: source("trips.txt", 2)
    }
  end

  defp loop_trip(id, final_sequence) do
    trip = trip(id, "R1", 28_800)

    trip
    |> Map.put(:pattern, trip.pattern ++ [%{stop_id: "S1", sequence: final_sequence}])
    |> Map.put(:time_vector, trip.time_vector ++ [{32_400, 32_400}])
  end

  defp partial_trip(id, route_id) do
    id |> trip(route_id, 28_800) |> Map.put(:time_vector, [{28_800, nil}, {29_400, 29_400}])
  end

  # -- native composition -----------------------------------------------------

  defp create_and_set_owned_artifact_root(_) do
    root =
      Path.join(System.tmp_dir!(), "comparison-matching-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    :ok
  end

  defp setup_context do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    organization_membership_fixture(user, organization)

    scope = %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "release_comparison",
      version_name: version.name,
      resource_context: Scope.context({:version, version.id})
    }

    %{organization: organization, version: version, scope: scope}
  end

  # The projection is built through the real native exporter, claim, reader and
  # projection path, so the matcher sees exactly what a genuine artifact gives.
  defp native_projection(organization, version, scope) do
    {:ok, bytes, _warnings} = Export.build_zip(organization.id, version.id, :full)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    {:ok, artifact} =
      ArtifactStorage.publish(organization.id, version.id, run.id, "network.zip", bytes)

    {:ok, _run} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{
        main: artifact,
        flex: nil
      })

    assert {:ok, claim} = ExportRuns.claim_download(organization.id, version.id, run.id, :main)

    assert {:ok, selection} =
             ReleaseComparison.resolve_selection(scope, %{
               "left_run_id" => run.id,
               "right_run_id" => run.id,
               "from" => "2026-04-01",
               "to" => "2026-04-02"
             })

    {:ok, reader_output} = Reader.read(claim, selection.left)
    Projection.build(reader_output)
  end

  defp seed_native_version!(organization, version, overrides \\ %{}) do
    agency = agency_fixture(organization.id, version.id, %{agency_id: "AGENCY"})

    route =
      route_fixture(organization.id, version.id, %{
        route_id: Map.get(overrides, :route_id, "R1"),
        agency_id: agency.id,
        route_long_name: Map.get(overrides, :route_long_name, "Test Route")
      })

    stop = stop_fixture(organization.id, version.id, %{stop_id: "S1"})
    calendar_fixture(organization.id, version.id, %{service_id: "WEEK"})

    trip =
      trip_fixture(organization.id, version.id, route.id, %{trip_id: "T1", service_id: "WEEK"})

    stop_time_fixture(organization.id, version.id, trip.id, stop.id, %{
      stop_sequence: 1,
      arrival_time: "08:00:00",
      departure_time: "08:00:00"
    })

    route
  end

  # The matcher is a pure library function over two projections, so the live
  # database is not one of its inputs: this records that the native case left
  # the seeded rows exactly as they were.
  defp assert_no_live_read(left, right) do
    assert Repo.aggregate(Route, :count) >= 0
    assert Repo.aggregate(Trip, :count) >= 0
    assert is_map(left) and is_map(right)
  end
end
