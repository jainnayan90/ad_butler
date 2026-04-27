defmodule AdButler.Meta.ClientBehaviour do
  @moduledoc """
  Behaviour for the Meta (Facebook) Graph API client.

  Defines the contract implemented by `AdButler.Meta.Client`. Inject a mock
  module via `Application.put_env(:ad_butler, :meta_client, MyMock)` in tests.
  """
  @callback list_ad_accounts(String.t()) :: {:ok, list(map())} | {:error, term()}
  @callback list_campaigns(String.t(), String.t(), keyword()) ::
              {:ok, list(map())} | {:error, term()}
  @callback list_ad_sets(String.t(), String.t(), keyword()) ::
              {:ok, list(map())} | {:error, term()}
  @callback list_ads(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  @callback get_creative(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback batch_request(String.t(), list(map())) :: {:ok, list(map())} | {:error, term()}
  @callback get_rate_limit_usage(String.t()) :: float()
  @callback refresh_token(String.t()) :: {:ok, map()} | {:error, term()}
  @callback exchange_code(String.t()) ::
              {:ok, %{access_token: String.t(), expires_in: pos_integer()}} | {:error, term()}
  @callback get_me(String.t()) :: {:ok, map()} | {:error, term()}

  @callback get_insights(
              ad_account_id :: String.t(),
              access_token :: String.t(),
              opts :: keyword()
            ) :: {:ok, [map()]} | {:error, term()}
end
