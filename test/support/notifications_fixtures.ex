defmodule AdButler.NotificationsFixtures do
  @moduledoc false

  import AdButler.Factory

  def user_with_finding(severity) do
    user = insert(:user)
    mc = insert(:meta_connection, user: user)
    aa = insert(:ad_account, meta_connection: mc)
    campaign = insert(:campaign, ad_account: aa)
    ad_set = insert(:ad_set, ad_account: aa, campaign: campaign)
    ad = insert(:ad, ad_account: aa, ad_set: ad_set)
    insert(:finding, ad_id: ad.id, ad_account_id: aa.id, severity: severity)
    user
  end

  def user_without_findings do
    user = insert(:user)
    insert(:meta_connection, user: user)
    user
  end
end
