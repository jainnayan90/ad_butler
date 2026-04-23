defmodule AdButlerWeb.PlugAttack do
  @moduledoc false
  use PlugAttack

  # 10 requests per 60 seconds per (client IP, route) on OAuth routes.
  # Keying by path prevents a flood on one route from consuming another's bucket.
  # Health paths are excluded so their separate looser limit (below) can apply.
  rule "oauth rate limit", conn do
    if not String.starts_with?(conn.request_path, "/health") do
      throttle({client_ip(conn), conn.request_path},
        period: 60_000,
        limit: 10,
        storage: {PlugAttack.Storage.Ets, :plug_attack_storage}
      )
    end
  end

  # 60 requests per 60 seconds per IP for health probe endpoints.
  # Loose limit to allow infra checks while preventing DB pool exhaustion.
  # NOTE: currently unreachable — the :health_check pipeline is intentionally
  # empty (no PlugAttack plug) to avoid Fly shared-IP prober restart loops.
  # Re-enable when per-IP health limiting is needed.
  rule "health rate limit", conn do
    if String.starts_with?(conn.request_path, "/health") do
      throttle(client_ip(conn),
        period: 60_000,
        limit: 60,
        storage: {PlugAttack.Storage.Ets, :plug_attack_storage}
      )
    end
  end

  # When trusted_proxy: :fly, reads fly-client-ip (Fly injects this and strips
  # client-supplied values, making it authoritative). Falls back to conn.remote_ip
  # if the header is absent or malformed. When trusted_proxy is not :fly, always
  # uses conn.remote_ip directly.
  defp client_ip(conn) do
    if Application.get_env(:ad_butler, :trusted_proxy) == :fly do
      case Plug.Conn.get_req_header(conn, "fly-client-ip") do
        [ip_str | _] -> parse_fly_ip(ip_str, conn)
        [] -> remote_ip(conn)
      end
    else
      remote_ip(conn)
    end
  end

  defp parse_fly_ip(ip_str, conn) do
    case :inet.parse_address(ip_str |> String.trim() |> to_charlist()) do
      {:ok, addr} -> :inet.ntoa(addr) |> to_string()
      {:error, _} -> remote_ip(conn)
    end
  end

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
