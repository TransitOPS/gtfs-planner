defmodule GtfsPlannerWeb.SecurityParameterFilterTest do
  use ExUnit.Case, async: true

  test "filters password and token parameter values" do
    params = %{
      "email" => "user@example.com",
      "password" => "secret123",
      "current_password" => "oldsecret",
      "password_confirmation" => "secret123",
      "token" => "abc123token",
      "user" => %{
        "id" => "42",
        "email" => "user@example.com",
        "password" => "newsecret",
        "password_confirmation" => "newsecret"
      }
    }

    filtered = Phoenix.Logger.filter_values(params)

    assert filtered == %{
             "email" => "user@example.com",
             "password" => "[FILTERED]",
             "current_password" => "[FILTERED]",
             "password_confirmation" => "[FILTERED]",
             "token" => "[FILTERED]",
             "user" => %{
               "id" => "42",
               "email" => "user@example.com",
               "password" => "[FILTERED]",
               "password_confirmation" => "[FILTERED]"
             }
           }
  end
end
