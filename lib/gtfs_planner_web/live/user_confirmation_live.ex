defmodule GtfsPlannerWeb.UserConfirmationLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.confirm_user(token) do
        {:ok, _user} ->
          socket
          |> redirect(to: ~p"/users/log_in")

        :error ->
          socket
          |> put_flash(:error, "Confirmation link is invalid or it has expired.")
          |> redirect(to: ~p"/")
      end

    {:ok, socket}
  end

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Confirm Email")
      |> assign(form: to_form(%{}, as: "user"))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <.header class="text-center">
        Resend confirmation instructions
        <:subtitle>Enter your email to receive a new confirmation link</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="resend_confirmation_form"
        phx-submit="send_instructions"
      >
        <.input field={@form[:email]} type="email" label="Email" required />

        <:actions>
          <.button phx-disable-with="Sending..." class="w-full" variant="primary">
            Resend confirmation instructions
          </.button>
        </:actions>
      </.simple_form>

      <p class="text-center mt-4 text-sm leading-6 text-base-content/70">
        <.link navigate={~p"/users/log_in"} class="font-semibold link link-primary">
          Log in
        </.link>
      </p>
    </Layouts.auth>
    """
  end

  @impl true
  def handle_event("send_instructions", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_confirmation_instructions(
        user,
        &url(~p"/users/confirm/#{&1}")
      )
    end

    info =
      "If your email is in our system and it has not been confirmed yet, you will receive an email with instructions shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: ~p"/")}
  end
end
