defmodule GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponentsTest do
  use ExUnit.Case, async: true

  alias GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponents

  test "exposes change_log_list/1 as a function component" do
    Code.ensure_loaded!(ChangeHistoryComponents)
    assert function_exported?(ChangeHistoryComponents, :change_log_list, 1)
  end
end
