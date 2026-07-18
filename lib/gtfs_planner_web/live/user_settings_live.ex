defmodule GtfsPlannerWeb.UserSettingsLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      user_roles={@user_roles}
    >
      <div class="space-y-12">
        <div>
          <.header>
            Account Settings
            <:subtitle>Manage your account email address and password settings.</:subtitle>
          </.header>

          <div class="space-y-12 max-w-3xl">
            <div>
              <.simple_form
                for={@email_form}
                id="email_form"
                phx-submit="update_email"
                phx-change="validate_email"
              >
                <.input
                  field={@email_form[:email]}
                  type="email"
                  label="Email"
                  required
                />

                <.input
                  field={@email_form[:current_password]}
                  type="password"
                  label="Current password"
                  value={@email_form_current_password}
                  required
                />

                <:actions>
                  <.button phx-disable-with="Changing...">Change Email</.button>
                </:actions>
              </.simple_form>
            </div>

            <div>
              <.simple_form
                for={@password_form}
                id="password_form"
                phx-submit="update_password"
                phx-change="validate_password"
                action={~p"/users/settings"}
              >
                <.input
                  field={@password_form[:current_password]}
                  type="password"
                  label="Current password"
                  value={@current_password}
                  required
                />

                <.input
                  field={@password_form[:password]}
                  type="password"
                  label="New password"
                  required
                />

                <.input
                  field={@password_form[:password_confirmation]}
                  type="password"
                  label="Confirm new password"
                  required
                />

                <:actions>
                  <.button phx-disable-with="Changing...">Change Password</.button>
                </:actions>
              </.simple_form>
            </div>
          </div>
        </div>

        <div>
          <.header>
            Email Change History
            <:subtitle>A list of all recent email changes in your account.</:subtitle>
          </.header>

          <.table
            id="emails"
            rows={@email_token}
            row_click={false}
          >
            <:col :let={token} label="Address">{token.sent_to}</:col>
            <:col :let={token} label="Status">
              <%= if token.context == "change:#{@current_user.email}" do %>
                Pending
              <% else %>
                Changed
              <% end %>
            </:col>
            <:col :let={token} label="Updated At">
              {token.inserted_at |> Calendar.strftime("%B %d, %Y %H:%M")}
            </:col>
          </.table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def mount(params, _session, socket) do
    # user_roles will be empty for this view as it doesn't use AssignOrganization hook
    user_roles = socket.assigns[:user_roles] || []

    socket =
      socket
      |> assign(:current_password, nil)
      |> assign(:email_form_current_password, nil)
      |> assign(:user_roles, user_roles)
      |> assign_forms(params)

    {:ok, socket}
  end

  defp assign_forms(socket, %{"action" => "update_email"} = params) do
    socket
    |> assign(:trigger_submit, true)
    |> assign(:current_action, "update_email")
    |> then(&assign_email_form(&1, params))
    |> assign_password_form()
  end

  defp assign_forms(socket, %{"action" => "update_password"} = params) do
    socket
    |> assign(:trigger_submit, true)
    |> assign(:current_action, "update_password")
    |> assign_email_form(%{})
    |> assign_password_form(params)
  end

  defp assign_forms(socket, _params) do
    socket
    |> assign(:trigger_submit, false)
    |> assign(:current_action, nil)
    |> assign_email_form(%{})
    |> assign_password_form()
  end

  defp assign_email_form(socket, %{"current_password" => password}) do
    assign(socket, :email_form_current_password, password)
  end

  defp assign_email_form(socket, _params) do
    current_user = socket.assigns.current_user

    if current_user do
      changeset = Accounts.change_user_email(current_user)
      assign(socket, :email_form, to_form(changeset))
    else
      socket
    end
  end

  defp assign_password_form(socket, params \\ %{}) do
    password_form =
      socket.assigns.current_user
      |> Accounts.change_user_password(params)
      |> to_form()

    assign(socket, :password_form, password_form)
  end

  def handle_event("validate_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    email_form =
      socket.assigns.current_user
      |> Accounts.change_user_email(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form, email_form_current_password: password)}
  end

  def handle_event("update_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.current_user

    socket =
      case Accounts.apply_user_email(user, password, user_params) do
        {:ok, applied_user} ->
          Accounts.deliver_user_confirmation_instructions(
            applied_user,
            &url(~p"/users/confirm/#{&1}")
          )

          socket
          |> put_flash(
            :info,
            "A link to confirm your email change has been sent to the new address."
          )
          |> assign(:current_user, applied_user)

        {:error, changeset} ->
          assign(socket, :email_form, to_form(Map.put(changeset, :action, :insert)))
      end

    {:noreply, socket}
  end

  def handle_event("validate_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    password_form =
      socket.assigns.current_user
      |> Accounts.change_user_password(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form, current_password: password)}
  end

  def handle_event("update_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.current_user

    socket =
      case Accounts.update_user_password(user, password, user_params) do
        {:ok, {user, _tokens}} ->
          socket
          |> put_flash(:info, "Password updated successfully.")
          |> assign(:current_user, user)
          |> assign(:current_password, nil)

        {:error, changeset} ->
          assign(socket, :password_form, to_form(Map.put(changeset, :action, :insert)))
      end

    {:noreply, socket}
  end
end
