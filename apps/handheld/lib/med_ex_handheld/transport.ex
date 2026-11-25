defmodule MedExHandheld.Transport do
  @moduledoc "Peer-verified TLS, one Gun connection per control or stream owner."
  def connect(config, route) do
    %URI{scheme: "wss", host: host, port: port, path: path} = URI.new!(config["server"])

    tls = [
      verify: :verify_peer,
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    trust =
      if file = config["ca_file"],
        do: [cacertfile: String.to_charlist(file)],
        else: [cacerts: :public_key.cacerts_get()]

    credential = File.read!(config["credential_file"]) |> String.trim()

    with {:ok, pid} <-
           :gun.open(String.to_charlist(host), port || 443, %{
             transport: :tls,
             tls_opts: tls ++ trust,
             protocols: [:http],
             retry: 0,
             connect_timeout: 5000
           }) do
      try do
        with {:ok, :http} <- :gun.await_up(pid, 5000),
             ref =
               :gun.ws_upgrade(
                 pid,
                 String.trim_trailing(path || "", "/") <> "/api/device/v1/" <> route,
                 [{"authorization", "Bearer " <> credential}]
               ),
             {:upgrade, ["websocket"], _} <- :gun.await(pid, ref, 5000) do
          {:ok, {pid, ref}}
        else
          _ ->
            :gun.close(pid)
            {:error, :upgrade_failed}
        end
      catch
        :exit, _ ->
          :gun.close(pid)
          {:error, :disconnected}
      end
    end
  end

  def send_json(s, type, body),
    do:
      send_frame(
        s,
        {:text, JSON.encode!(Map.merge(body, %{"schema" => "medex.device.v1", "type" => type}))}
      )

  def send_frame({pid, ref}, frame), do: :gun.ws_send(pid, ref, frame)

  def recv({pid, ref}, timeout \\ 6000) do
    case :gun.await(pid, ref, timeout) do
      {:ws, {:text, "device_request_denied"}} ->
        {:error, :denied}

      {:ws, {:close, 1008, _}} ->
        {:error, :denied}

      {:ws, {:text, bytes}} when byte_size(bytes) <= 16_384 ->
        types =
          ~w(admitted durable accepted stream_finished replay monitor_credit heartbeat command state_query result_saved quarantined probe recorded sealed inventory_pending)

        MedEx.Wire.Control.decode(bytes, types)

      other ->
        {:error, {:transport, other}}
    end
  end

  def request(s, type, body \\ %{}) do
    with :ok <- send_json(s, type, body), do: recv(s)
  end

  def close({pid, _}), do: :gun.close(pid)
end
