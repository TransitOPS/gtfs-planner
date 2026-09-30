defmodule GtfsPlanner.Repo.Migrations.AddRoutePatternLabels do
  use Ecto.Migration

  # A pattern may name another pattern of the same route, version and direction
  # as its label owner, so a label reads as one row instead of a group. The
  # reference is restricted rather than cascading: an owner that still has
  # children is a live label and must be removed, not silently dissolved, and
  # the pair check keeps a pattern from owning itself, which would make the
  # label read as a cycle of length one.
  def change do
    alter table(:route_patterns) do
      add :label_pattern_id,
          references(:route_patterns, type: :binary_id, on_delete: :restrict),
          null: true
    end

    # The delete guard looks up children by owner, so the column is indexed on
    # its own rather than in a compound with the scope columns the query also
    # filters on.
    create index(:route_patterns, [:label_pattern_id])

    create constraint(:route_patterns, :route_patterns_label_not_self,
             check: "label_pattern_id IS NULL OR label_pattern_id <> id"
           )
  end
end
