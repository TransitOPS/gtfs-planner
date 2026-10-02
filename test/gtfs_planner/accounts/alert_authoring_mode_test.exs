defmodule GtfsPlanner.Accounts.AlertAuthoringModeTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User

  describe "alert_authoring_mode_changeset/2" do
    test "is valid for :form and :assistant and casts the atom" do
      for mode <- [:form, :assistant] do
        changeset = User.alert_authoring_mode_changeset(%User{}, %{alert_authoring_mode: mode})

        assert changeset.valid?
        assert get_field(changeset, :alert_authoring_mode) == mode
      end
    end

    test "is valid for the string forms of the two modes" do
      for mode <- ["form", "assistant"] do
        changeset = User.alert_authoring_mode_changeset(%User{}, %{alert_authoring_mode: mode})

        assert changeset.valid?
        assert Enum.member?([:form, :assistant], get_field(changeset, :alert_authoring_mode))
      end
    end

    test "is invalid for any other mode" do
      for mode <- ["chat", "", :chat, nil] do
        changeset = User.alert_authoring_mode_changeset(%User{}, %{alert_authoring_mode: mode})

        refute changeset.valid?
        assert %{alert_authoring_mode: [_ | _]} = errors_on(changeset)
      end
    end
  end

  describe "update_alert_authoring_mode/2" do
    test "stores :assistant for that user and leaves another user's row at :form" do
      user = user_fixture()
      other_user = user_fixture()

      assert {:ok, updated} = Accounts.update_alert_authoring_mode(user, :assistant)
      assert updated.alert_authoring_mode == :assistant

      assert Repo.get!(User, user.id).alert_authoring_mode == :assistant
      assert Repo.get!(User, other_user.id).alert_authoring_mode == :form
    end

    test "stores the string forms the browser form params carry" do
      user = user_fixture()

      assert {:ok, updated} = Accounts.update_alert_authoring_mode(user, "assistant")
      assert updated.alert_authoring_mode == :assistant
      assert Repo.get!(User, user.id).alert_authoring_mode == :assistant

      assert {:ok, updated} = Accounts.update_alert_authoring_mode(updated, "form")
      assert updated.alert_authoring_mode == :form
      assert Repo.get!(User, user.id).alert_authoring_mode == :form
    end

    test "a new user defaults to :form" do
      user = user_fixture()

      assert Repo.get!(User, user.id).alert_authoring_mode == :form
    end

    test "rejects an unknown mode without storing it" do
      user = user_fixture()

      assert {:ok, updated} = Accounts.update_alert_authoring_mode(user, :assistant)
      assert updated.alert_authoring_mode == :assistant

      assert {:error, changeset} = Accounts.update_alert_authoring_mode(updated, "chat")
      assert %{alert_authoring_mode: ["is invalid"]} = errors_on(changeset)
      assert Repo.get!(User, user.id).alert_authoring_mode == :assistant
    end

    test "rejects a missing mode" do
      user = user_fixture()

      assert {:error, changeset} = Accounts.update_alert_authoring_mode(user, nil)
      assert %{alert_authoring_mode: [_ | _]} = errors_on(changeset)
      assert Repo.get!(User, user.id).alert_authoring_mode == :form
    end

    test "stores only the preference and leaves the rest of the row alone" do
      user = user_fixture()

      assert {:ok, updated} = Accounts.update_alert_authoring_mode(user, :assistant)

      assert updated.email == user.email
      assert updated.confirmed_at == user.confirmed_at
      assert Repo.get!(User, user.id).email == user.email
    end
  end
end
