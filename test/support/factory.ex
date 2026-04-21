defmodule AdButler.Factory do
  @moduledoc false
  use ExMachina.Ecto, repo: AdButler.Repo

  alias AdButler.Accounts.{MetaConnection, User}

  def user_factory do
    %User{
      email: sequence(:email, &"user#{&1}@example.com"),
      name: sequence(:name, &"User #{&1}"),
      meta_user_id: sequence(:meta_user_id, &"#{100_000 + &1}")
    }
  end

  def meta_connection_factory do
    %MetaConnection{
      user: build(:user),
      meta_user_id: sequence(:mc_meta_user_id, &"#{200_000 + &1}"),
      access_token: sequence(:access_token, &"token_#{&1}"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 60 * 24 * 60 * 60, :second),
      scopes: ["ads_read", "ads_management"],
      status: "active"
    }
  end
end
