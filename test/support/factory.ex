defmodule AdButler.Factory do
  @moduledoc false
  use ExMachina.Ecto, repo: AdButler.Repo

  alias AdButler.Accounts.{MetaConnection, User}
  alias AdButler.Ads.{Ad, AdAccount, AdSet, Campaign, Creative}

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

  def ad_account_factory do
    %AdAccount{
      meta_connection: build(:meta_connection),
      meta_id: sequence(:aa_meta_id, &"act_#{100 + &1}"),
      name: sequence(:aa_name, &"Ad Account #{&1}"),
      currency: "USD",
      timezone_name: "America/New_York",
      status: "ACTIVE",
      raw_jsonb: %{}
    }
  end

  def campaign_factory do
    %Campaign{
      ad_account: build(:ad_account),
      meta_id: sequence(:campaign_meta_id, &"campaign_#{100 + &1}"),
      name: sequence(:campaign_name, &"Campaign #{&1}"),
      status: "ACTIVE",
      objective: "OUTCOME_TRAFFIC",
      raw_jsonb: %{}
    }
  end

  # ExMachina note: ad_account is shared so the default graph is internally consistent.
  # Overriding only ad_account: (without campaign:) will diverge campaign.ad_account_id —
  # callers that need full consistency must pass both associations explicitly.
  def ad_set_factory do
    ad_account = build(:ad_account)

    %AdSet{
      ad_account: ad_account,
      campaign: build(:campaign, ad_account: ad_account),
      meta_id: sequence(:ad_set_meta_id, &"adset_#{100 + &1}"),
      name: sequence(:ad_set_name, &"Ad Set #{&1}"),
      status: "ACTIVE",
      raw_jsonb: %{}
    }
  end

  def ad_factory do
    ad_set = build(:ad_set)

    %Ad{
      ad_account: ad_set.ad_account,
      ad_set: ad_set,
      meta_id: sequence(:ad_meta_id, &"ad_#{100 + &1}"),
      name: sequence(:ad_name, &"Ad #{&1}"),
      status: "ACTIVE",
      raw_jsonb: %{}
    }
  end

  def creative_factory do
    %Creative{
      ad_account: build(:ad_account),
      meta_id: sequence(:creative_meta_id, &"creative_#{100 + &1}"),
      name: sequence(:creative_name, &"Creative #{&1}"),
      asset_specs_jsonb: %{},
      raw_jsonb: %{}
    }
  end
end
