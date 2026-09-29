defmodule GtfsPlannerWeb.AuthComponents do
  @moduledoc """
  Building blocks for the signed-out pages that sit inside `Layouts.auth`:
  the card heading, the one primary action, and the text link beside it.

  They carry the design system's signed-out grammar (28px heading over a 15px
  lede, a full-width 44px primary button, a 44px text link) so login and the
  account-recovery pages read as one family. Form fields are not here: those
  are `<.input>` inside a `.auth-form`, restyled by `app.css`.
  """
  use Phoenix.Component

  @doc """
  The card heading, with an optional one-sentence lede under it.

  ## Examples

      <.auth_title id="login-title">Log in</.auth_title>

      <.auth_title id="reset-password-request-title">
        Reset your password
        <:lede>Enter the email you log in with.</:lede>
      </.auth_title>
  """
  attr :id, :string, required: true
  slot :inner_block, required: true
  slot :lede

  def auth_title(assigns) do
    ~H"""
    <h1
      id={@id}
      class="font-display text-[28px] font-semibold leading-[1.08] tracking-[-0.035em] text-strong"
    >
      {render_slot(@inner_block)}
    </h1>
    <p :if={@lede != []} class="mt-2 text-[15px] leading-relaxed text-default">
      {render_slot(@lede)}
    </p>
    """
  end

  @doc """
  The card's one primary action. `phx-disable-with` supplies the busy label.
  """
  attr :class, :any, default: "mt-4"
  attr :rest, :global, include: ~w(disabled form name value)
  slot :inner_block, required: true

  def auth_submit(assigns) do
    ~H"""
    <button
      type="submit"
      class={[
        "min-h-11 w-full rounded-control bg-action text-sm font-semibold text-white hover:bg-action-hover disabled:cursor-progress disabled:hover:bg-action",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  A text link to another signed-out page. It is a 44px target, so it reads as
  a secondary route rather than prose.
  """
  attr :rest, :global, include: ~w(navigate patch href)
  slot :inner_block, required: true

  def auth_link(assigns) do
    ~H"""
    <.link class="inline-flex min-h-11 items-center text-sm font-semibold text-action" {@rest}>
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
