defmodule GtfsPlannerWeb.DemoLive do
  use GtfsPlannerWeb, :live_view

  def render(assigns) do
    ~H"""
    <div class="p-10">
      <h1 class="text-2xl mb-4">Salad UI Demo</h1>
      <.button>Salad UI Setup Complete!</.button>
      <p class="mt-4 text-gray-600">Salad UI has been successfully installed and configured.</p>
    </div>
    """
  end
end
