defmodule GtfsPlannerWeb.PageController do
  use GtfsPlannerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
