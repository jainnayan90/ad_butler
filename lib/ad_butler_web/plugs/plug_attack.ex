defmodule AdButlerWeb.PlugAttack do
  @moduledoc false
  use PlugAttack

  # 10 requests per 60 seconds per (client IP, route) on OAuth routes.
  # Keying by path prevents a flood on one route from consuming another's bucket.
  rule "oauth rate limit", conn do
    throttle({client_ip(conn), conn.request_path},
      period: 60_000,
      limit: 10,
      storage: {PlugAttack.Storage.Ets, :plug_attack_storage}
    )
  end

  # When trusted_proxy: :fly, reads fly-client-ip (Fly injects this and strips
  # client-supplied values, making it authoritative). Falls back to conn.remote_ip
  # if the header is absent or malformed. When trusted_proxy is not :fly, always
  # uses conn.remote_ip directly.
  defp client_ip(conn) do
    if Application.get_env(:ad_butler, :trusted_proxy) == :fly do
      case Plug.Conn.get_req_header(conn, "fly-client-ip") do
        [ip_str | _] ->
          case :inet.parse_address(ip_str |> String.trim() |> to_charlist()) do
            {:ok, addr} -> :inet.ntoa(addr) |> to_string()
            {:error, _} -> remote_ip(conn)
          end

        [] ->
          remote_ip(conn)
      end
    else
      remote_ip(conn)
    end
  end

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
