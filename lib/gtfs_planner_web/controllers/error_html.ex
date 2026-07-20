defmodule GtfsPlannerWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use GtfsPlannerWeb, :html

  # Embeds the dedicated 404 and 500 templates under `error_html/`. The
  # catch-all `render/2` below continues to handle every other status name
  # (e.g. `422.html`) by falling back to Phoenix's status phrase.
  embed_templates "error_html/*"

  # The default is to render a plain text page based on
  # the template name. For example, "422.html" becomes
  # "Unprocessable Content".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
