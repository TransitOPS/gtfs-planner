defmodule GtfsPlannerWeb.ComponentsLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures

  describe "ComponentsLive" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "redirects unauthenticated users to login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/components")
    end

    test "renders components page for authenticated users", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/components")

      assert html =~ "UI Components Demo"
      assert html =~ "Address Autocomplete"
    end

    test "displays the address autocomplete form", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/components")

      # Check that the form exists
      assert has_element?(view, "#address-form")

      # Check that the LiveSelect component is present
      assert has_element?(view, "#address_autocomplete")
    end

    test "updates on address selection", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/components")

      # Verify initial state - no selected address
      refute has_element?(view, "dt", "Address")

      # Set expectation on the mock
      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "Regent", _opts ->
        {:ok,
         [
           %GtfsPlanner.Geocoding.Result{
             formatted_address: "Regent Street, London, UK",
             lat: 51.5105,
             lon: -0.1367,
             country: "UK",
             state: "England",
             city: "London"
           }
         ]}
      end)

      # Simulate a live_select_change event with text input
      render_hook(view, "live_select_change", %{
        "text" => "Regent",
        "id" => "address_autocomplete"
      })

      # Then, simulate the form change event that happens on selection
      render_change(view, "address-form", %{
        "address_search" => %{"address_autocomplete" => "Regent Street, London, UK"}
      })

      # Verify that the selected address is displayed
      assert has_element?(view, "dt", "Address")
      assert render(view) =~ "Regent Street, London, UK"
    end

    test "does not display selected location initially", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/components")

      refute html =~ "Selected Location"
      refute html =~ "Latitude"
      refute html =~ "Longitude"
    end
  end
end
