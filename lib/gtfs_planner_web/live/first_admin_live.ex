defmodule GtfsPlannerWeb.FirstAdminLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <.header class="text-center">
        Welcome to Pathways Studio
        <:subtitle>Set up your administrator account and organization</:subtitle>
      </.header>

      <.simple_form for={@form} id="first_admin_form" phx-submit="setup" phx-change="validate">
        <.input
          field={@form[:email]}
          type="email"
          label="Email"
          placeholder="admin@company.com"
          required
        />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          required
        />
        <.input
          field={@form[:password_confirmation]}
          type="password"
          label="Confirm password"
          required
        />
        <.input
          field={@form[:organization_name]}
          type="text"
          label="Organization name"
          placeholder="My Transit Agency"
          required
        />
        <.input
          field={@form[:organization_alias]}
          type="text"
          label="Organization alias (optional)"
          placeholder="my-transit-agency"
          help="Used in URLs, e.g., /gtfs/my-transit-agency"
        />
        <:actions>
          <.button phx-disable-with="Setting up..." class="w-full" variant="primary">
            Create administrator account
          </.button>
        </:actions>
      </.simple_form>
    </Layouts.auth>
    """
  end

  def mount(_params, _session, socket) do
    if Accounts.count_users() > 0 do
      {:ok, redirect(socket, to: ~p"/")}
    else
      form = to_form(%{}, as: "admin")

      {:ok,
       socket
       |> assign(form: form)
       |> assign(page_title: "Setup Administrator")}
    end
  end

  def handle_event("setup", %{"admin" => admin_params}, socket) do
    user_attrs = %{
      "email" => admin_params["email"],
      "password" => admin_params["password"],
      "password_confirmation" => admin_params["password_confirmation"]
    }

    org_attrs = %{
      "name" => admin_params["organization_name"],
      "alias" =>
        admin_params["organization_alias"] ||
          generate_alias(admin_params["organization_name"])
    }

    case Accounts.register_first_admin(user_attrs, org_attrs) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> redirect(to: ~p"/users/log_in")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "admin"))}
    end
  end

  def handle_event("validate", %{"admin" => admin_params}, socket) do
    changeset =
      Accounts.change_user_registration(
        %GtfsPlanner.Accounts.User{},
        %{
          email: admin_params["email"],
          password: admin_params["password"],
          password_confirmation: admin_params["password_confirmation"]
        }
      )
      |> Map.put(:action, :validate)

    # Use raw params to preserve ALL fields, pass changeset errors for validation
    {:noreply, assign(socket, form: to_form(admin_params, as: "admin", errors: changeset.errors))}
  end

  defp generate_alias(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
