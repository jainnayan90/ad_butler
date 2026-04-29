defmodule AdButler.Factory do
  @moduledoc false
  use ExMachina.Ecto, repo: AdButler.Repo

  alias AdButler.Accounts.{MetaConnection, User}
  alias AdButler.Ads.{Ad, AdAccount, AdSet, Campaign, Creative}
  alias AdButler.Analytics.{AdHealthScore, Finding}

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

  # ExMachina note: ad_account is derived from the internally-built ad_set so the default
  # graph is consistent. Overriding only ad_set: (without ad_account:) or only ad_account:
  # (without ad_set:) will diverge the two associations — callers must pass both explicitly.
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

  # ExMachina.Ecto generates a UUID for ad.id (autogenerate: true) even on build.
  # All test callers MUST override ad_id/ad_account_id with IDs from inserted records
  # to satisfy FK constraints. Never call insert(:finding) without these overrides.
  def finding_factory do
    ad = build(:ad)

    %Finding{
      ad_id: ad.id,
      ad_account_id: ad.ad_account_id,
      kind: "dead_spend",
      severity: "high",
      title: "Dead spend detected",
      body: "Ad has spent with zero conversions",
      evidence: %{"spend_cents" => 1000, "period_hours" => 48, "conversions" => 0}
    }
  end

  # Same note as finding_factory — override ad_id with an inserted ad's ID.
  def ad_health_score_factory do
    %AdHealthScore{
      ad_id: build(:ad).id,
      computed_at: DateTime.utc_now(),
      leak_score: Decimal.new("0.00"),
      leak_factors: %{}
    }
  end
end
