defmodule GtfsPlannerWeb.UserConfirmationLive do
  use GtfsPlannerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Confirm Email")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header class="text-center">
        Confirm Your Email
        <:subtitle>Please confirm your email address to complete registration.</:subtitle>
      </.header>
      <p>Email confirmation will be implemented here.</p>
    </Layouts.app>
    """
  end
end
