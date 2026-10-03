defmodule GtfsPlanner.Gtfs.RoutePatterns.LabelsTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatterns.LabelRules
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = editor_fixture(organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    stops = for _name <- ["A", "B"], do: stop_fixture(organization.id, version.id)

    %{organization: organization, version: version, route: route, audit: audit, stops: stops}
  end

  describe "LabelRules.validate/2" do
    test "accepts a child and owner that share organization, version, route and direction" do
      owner = pattern()

      assert LabelRules.validate(sibling(owner), owner) == :ok
    end

    test "refuses a different organization, version or route as out of scope" do
      owner = pattern()

      assert {:error, :label_scope} ==
               LabelRules.validate(
                 sibling(owner, %{organization_id: Ecto.UUID.generate()}),
                 owner
               )

      assert {:error, :label_scope} ==
               LabelRules.validate(
                 sibling(owner, %{gtfs_version_id: Ecto.UUID.generate()}),
                 owner
               )

      assert {:error, :label_scope} ==
               LabelRules.validate(sibling(owner, %{route_id: "route-2"}), owner)
    end

    test "refuses a missing owner as out of scope" do
      assert {:error, :label_scope} == LabelRules.validate(pattern(), nil)
    end

    test "refuses a different direction once the scope agrees" do
      owner = pattern(%{direction_id: 1})

      assert {:error, :label_direction} ==
               LabelRules.validate(sibling(owner, %{direction_id: 0}), owner)

      assert LabelRules.validate(sibling(owner, %{direction_id: 1}), owner) == :ok
    end

    test "refuses an owner that already carries a label so depth stays one" do
      owner = pattern(%{label_pattern_id: Ecto.UUID.generate()})

      assert {:error, :label_depth} == LabelRules.validate(sibling(owner), owner)
    end
  end

  test "deleting an owner with a child is refused and deletes nothing", context do
    owner = create_pattern(context, "Owner")
    child = create_pattern(context, "Child")
    label!(child, owner)
    audits_before = count_audits(context)

    {:ok, %{fingerprint: fingerprint}} = Gtfs.review(owner.id, :delete, nil, context.audit)

    assert {:error, :label_in_use} ==
             Gtfs.apply_review(owner.id, :delete, fingerprint, context.audit)

    assert Repo.get(RoutePattern, owner.id)
    assert Repo.get(RoutePattern, child.id)
    assert Repo.get!(RoutePattern, child.id).label_pattern_id == owner.route_pattern_id
    assert count_audits(context) == audits_before
  end

  test "removing a label clears the owner, audits the transition and keeps the pattern",
       context do
    owner = create_pattern(context, "Owner")
    child = create_pattern(context, "Child")
    label!(child, owner)

    assert {:ok, unlabelled} =
             Gtfs.remove_route_pattern_label(context.route.route_id, child.id, context.audit)

    assert is_nil(unlabelled.label_pattern_id)
    assert Repo.get!(RoutePattern, child.id).label_pattern_id == nil

    # The owner is untouched: a label is a pointer, not a change to the pattern
    # that is pointed at.
    assert Repo.get!(RoutePattern, owner.id).label_pattern_id == nil

    [log] =
      Repo.all(
        from log in ChangeLog,
          where:
            log.entity_type == "route_pattern" and log.entity_id == ^child.id and
              log.action == "updated",
          order_by: [desc: log.inserted_at]
      )

    assert log.changed_fields["before"]["to"]["label_pattern_id"] == owner.route_pattern_id
    assert log.changed_fields["after"]["to"]["label_pattern_id"] == nil
  end

  test "removing a label from an unlabelled pattern is refused and audits nothing", context do
    owner = create_pattern(context, "Owner")
    audits_before = count_audits(context)

    assert {:error, :not_labelled} ==
             Gtfs.remove_route_pattern_label(context.route.route_id, owner.id, context.audit)

    assert Repo.get!(RoutePattern, owner.id).label_pattern_id == nil
    assert count_audits(context) == audits_before
  end

  test "removing a label outside the audit context's route is not found", context do
    assert {:error, :not_found} =
             Gtfs.remove_route_pattern_label(
               context.route.route_id,
               Ecto.UUID.generate(),
               context.audit
             )
  end

  test "the database refuses a pattern that labels itself", context do
    pattern = create_pattern(context, "Self")

    assert_raise Postgrex.Error, ~r/route_patterns_label_not_self/, fn ->
      Repo.update_all(
        from(p in RoutePattern,
          where: p.id == ^pattern.id,
          update: [set: [label_pattern_id: fragment("?", p.route_pattern_id)]]
        ),
        []
      )
    end
  end

  test "an exported label resolves its owner inside the pattern's own scope", context do
    owner = create_pattern(context, "Owner")
    child = create_pattern(context, "Child")
    label!(child, owner)

    # The same pattern IDs exist in a sibling version and another organization,
    # labelled the other way round. They must not add rows to this version's
    # export nor change which owner the child exports under.
    sibling_version = gtfs_version_fixture(context.organization.id)
    foreign_org = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_org.id)

    for {organization, version} <- [
          {context.organization, sibling_version},
          {foreign_org, foreign_version}
        ] do
      route_pattern_fixture(organization.id, version.id, %{
        route_pattern_id: owner.route_pattern_id,
        route_id: owner.route_id
      })

      route_pattern_fixture(organization.id, version.id, %{
        route_pattern_id: child.route_pattern_id,
        route_id: owner.route_id
      })
    end

    exported =
      from(
        p in subquery(
          RoutePatterns.exported_pattern_ids(context.organization.id, context.version.id)
        ),
        select: {p.route_pattern_id, p.exported_id}
      )
      |> Repo.all()
      |> Enum.sort()

    assert exported ==
             Enum.sort([
               {owner.route_pattern_id, owner.route_pattern_id},
               {child.route_pattern_id, owner.route_pattern_id}
             ])
  end

  test "the database refuses a label owner that exists only in another version", context do
    child = create_pattern(context, "Child")
    sibling_version = gtfs_version_fixture(context.organization.id)

    route_pattern_fixture(context.organization.id, sibling_version.id, %{
      route_pattern_id: "ONLY-THERE",
      route_id: child.route_id
    })

    assert_raise Postgrex.Error, ~r/route_patterns_label_pattern_id_fkey/, fn ->
      Repo.update_all(from(p in RoutePattern, where: p.id == ^child.id),
        set: [label_pattern_id: "ONLY-THERE"]
      )
    end
  end

  defp create_pattern(context, name) do
    {:ok, pattern} =
      Gtfs.create_pattern(
        context.route.route_id,
        %{
          route_pattern_name: name,
          direction_id: 0,
          route_pattern_typicality: 1,
          stops: Enum.map(context.stops, & &1.stop_id)
        },
        context.audit
      )

    pattern
  end

  # Labels are written by derivation and review, neither of which exists yet, so
  # the fixture writes the pointer the way those writers will: as a direct
  # update of the never-cast column.
  defp label!(child, owner) do
    {1, nil} =
      Repo.update_all(
        from(p in RoutePattern, where: p.id == ^child.id),
        set: [label_pattern_id: owner.route_pattern_id]
      )

    Repo.get!(RoutePattern, child.id)
  end

  defp count_audits(context) do
    Repo.aggregate(
      from(log in ChangeLog, where: log.organization_id == ^context.organization.id),
      :count,
      :id
    )
  end

  defp pattern(attrs \\ %{}) do
    struct!(
      %RoutePattern{
        id: Ecto.UUID.generate(),
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate(),
        route_pattern_id: "route_pattern",
        route_id: "route-1",
        direction_id: 0,
        label_pattern_id: nil
      },
      attrs
    )
  end

  # A child is only ever the owner's own scope, so the two are built from one
  # set of identities and differ only where a test says they do.
  defp sibling(owner, attrs \\ %{}) do
    pattern(
      Map.merge(
        %{
          organization_id: owner.organization_id,
          gtfs_version_id: owner.gtfs_version_id,
          route_id: owner.route_id,
          direction_id: owner.direction_id
        },
        attrs
      )
    )
  end
end
