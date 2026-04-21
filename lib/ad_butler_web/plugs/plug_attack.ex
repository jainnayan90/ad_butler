defmodule AdButlerWeb.PlugAttack do
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

  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "fly-client-ip") do
      [ip | _] -> ip
      [] -> xff_ip(conn)
    end
  end

  # NOTE: XFF leftmost-entry trust is only safe on Fly.io, where fly-client-ip
  # is preferred above and Fly strips client-supplied XFF values on ingress.
  # On other platforms, leftmost XFF is attacker-controlled — gate behind a flag.
  defp xff_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> Enum.map(&String.trim/1) |> List.first()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
