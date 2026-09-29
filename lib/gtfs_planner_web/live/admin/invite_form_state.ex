defmodule GtfsPlannerWeb.Admin.InviteFormState do
  @moduledoc """
  The invitation form's assigns and the wording of its errors, shared by the
  administration LiveViews that open `GtfsPlannerWeb.Admin.Components.invite_form/1`.

  Each error sentence is chosen by the rule that failed, so it says what to enter
  instead of repeating the changeset's wording. A rejected submit also produces
  the failure list the form's error summary links from; live validation is not a
  rejection and never produces one.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2, used_input?: 1]

  alias GtfsPlannerWeb.Admin.Components
  alias GtfsPlannerWeb.CoreComponents

  @doc """
  Assigns the invite form and the error state the form component reads:
  `:invite_form`, `:invite_email_errors`, `:invite_roles_error`,
  `:invite_base_error` and `:invite_failures`.
  """
  def assign_invite_form(socket, changeset) do
    form = to_form(changeset, as: :invite)
    email_errors = email_errors(form, changeset)
    roles_error = roles_error(changeset)

    socket
    |> assign(:invite_form, form)
    |> assign(:invite_email_errors, email_errors)
    |> assign(:invite_roles_error, roles_error)
    |> assign(:invite_base_error, List.first(field_errors(changeset, :base)))
    |> assign(:invite_failures, invite_failures(changeset, email_errors, roles_error))
  end

  @doc "Roles arrive as a list, a map, or not at all when every box is unchecked."
  def normalize_invite_params(params) do
    roles =
      case Map.get(params, "roles") do
        nil -> []
        roles when is_list(roles) -> roles
        roles when is_map(roles) -> Map.values(roles)
        role -> [role]
      end

    Map.put(params, "roles", roles)
  end

  @doc """
  The second line of the message that reports a sent invitation: what state the
  invited person shows in, which depends on whether the address already had an
  account.
  """
  def invitation_detail(%{hashed_password: nil}),
    do: "They show as Invitation pending until they set a password. The link works for 7 days."

  def invitation_detail(_user),
    do: "They already have an account, so they show as Active."

  defp field_errors(changeset, field) do
    for {^field, error} <- changeset.errors, do: CoreComponents.translate_error(error)
  end

  # On submit the errors are authoritative and always shown. While changing, an
  # email shows its errors once the person has used the field.
  defp email_errors(form, changeset) do
    if changeset.action == :insert or used_input?(form[:email]) do
      for {:email, error} <- changeset.errors, do: email_message(error)
    else
      []
    end
  end

  defp email_message({_message, opts} = error) do
    case {opts[:validation], opts[:kind]} do
      {:required, _kind} -> "Enter an email address."
      {:format, _kind} -> "Enter a valid email address, such as name@agency.org."
      {:length, :max} -> "Use #{opts[:count]} characters or fewer."
      _other -> CoreComponents.translate_error(error)
    end
  end

  # A checkbox group has no useful blur, so its error appears on submit and on
  # any change the operator actually made to the group.
  defp roles_error(%Ecto.Changeset{action: nil}), do: nil

  defp roles_error(%Ecto.Changeset{action: :validate, params: params} = changeset) do
    if Map.has_key?(params, "_unused_roles"),
      do: nil,
      else: changeset |> role_messages() |> List.first()
  end

  defp roles_error(changeset), do: changeset |> role_messages() |> List.first()

  defp role_messages(changeset) do
    for {:roles, {message, _opts}} <- changeset.errors do
      case message do
        "must select at least one role" -> "Choose at least one access level."
        "contains an invalid role" -> "Choose a valid access level."
        other -> other
      end
    end
  end

  defp invite_failures(%Ecto.Changeset{action: :insert}, email_errors, roles_error) do
    first_role = Components.access_levels() |> List.first() |> Map.fetch!(:value)

    [
      {List.first(email_errors), "#invite-email"},
      {roles_error, "#invite-roles-#{first_role}"}
    ]
    |> Enum.filter(fn {message, _href} -> message end)
    |> Enum.map(fn {message, href} -> %{href: href, msg: message} end)
  end

  defp invite_failures(_changeset, _email_errors, _roles_error), do: []
end
