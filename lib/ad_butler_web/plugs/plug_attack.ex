defmodule AdButlerWeb.PlugAttack do
  @moduledoc false
  use PlugAttack

  # 10 requests per 60 seconds per (client IP, route) on OAuth routes.
  # Keying by path prevents a flood on one route from consuming another's
  # bucket. Fly.io appends its hop to X-Forwarded-For (does not replace it),
  # so prefer the fly-client-ip header (Fly strips client-supplied values).
  rule "oauth rate limit", conn do
    throttle({client_ip(conn), conn.request_path},
      period: 60_000,
      limit: 10,
      storage: {PlugAttack.Storage.Ets, :plug_attack_storage}
    )
  end

  # Fly.io injects fly-client-ip and strips any client-supplied value, so it's
  # the authoritative real-IP source on Fly deployments. Falls back to
  # conn.remote_ip on non-Fly environments (local dev, other hosting).
  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "fly-client-ip") do
      [ip | _] -> ip
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
