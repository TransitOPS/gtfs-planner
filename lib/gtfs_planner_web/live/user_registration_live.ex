defmodule GtfsPlannerWeb.UserRegistrationLive do
  use GtfsPlannerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Register")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header class="text-center">
        Create an Account
        <:subtitle>Sign up to get started with GTFS Planner.</:subtitle>
      </.header>
      <p>Registration form will be implemented here.</p>
    </Layouts.app>
    """
  end
end
