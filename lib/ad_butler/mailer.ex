defmodule AdButler.Mailer do
  @moduledoc """
  Swoosh mailer for AdButler. Adapter is configured per environment in `config/`.
  """

  use Swoosh.Mailer, otp_app: :ad_butler
end
