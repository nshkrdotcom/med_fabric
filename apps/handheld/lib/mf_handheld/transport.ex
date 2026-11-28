defmodule MedFabric.Handheld.Transport do
  @moduledoc "Verified TLS and bounded revision-2 messages. Authentication never implies continuing acquisition authority."
  alias MedEx.Wire.Control

  @replies ~w(admitted durable accepted stream_finished replay monitor_credit heartbeat_reply command state_query result_saved quarantined probe recorded sealed inventory_pending refused)

  def validate_config(config) when is_map(config) do
    with value when is_binary(value) <- config["server"],
         true <- byte_size(value) <= 2048,
         {:ok, %URI{scheme: "wss", host: host, userinfo: nil, query: nil, fragment: nil} = uri} <-
           URI.new(value),
         true <- is_binary(host) and byte_size(host) in 1..253,
         true <- uri.port == nil or uri.port in 1..65_535,
         true <-
           uri.path == nil or
             (String.starts_with?(uri.path, "/") and
                not String.contains?(uri.path, ["..", "\\", <<0>>])),
         credential when is_binary(credential) <- config["credential_file"],
         true <- Path.type(credential) == :absolute,
         :ok <- regular_file(credential, 4097),
         :ok <- trust_file(config["ca_file"]) do
      {:ok, uri}
    else
      _ -> {:error, :invalid_transport_configuration}
    end
  end

  def validate_config(_), do: {:error, :invalid_transport_configuration}

  def connect(config, route) when route in ["control", "stream", "monitor"] do
    with {:ok, uri} <- validate_config(config),
         {:ok, bytes} <- File.read(config["credential_file"]),
         credential = String.trim(bytes),
         true <- byte_size(credential) in 16..4096 do
      tls = [
        verify: :verify_peer,
        server_name_indication: String.to_charlist(uri.host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

      trust =
        if config["ca_file"],
          do: [cacertfile: String.to_charlist(config["ca_file"])],
          else: [cacerts: :public_key.cacerts_get()]

      case :gun.open(String.to_charlist(uri.host), uri.port || 443, %{
             transport: :tls,
             tls_opts: tls ++ trust,
             protocols: [:http],
             retry: 0,
             connect_timeout: 5_000
           }) do
        {:ok, pid} -> upgrade(pid, uri, route, credential)
        _ -> {:error, :connect_failed}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_credential}
    end
  catch
    :exit, _ -> {:error, :disconnected}
  end

  def connect(_, _), do: {:error, :invalid_route}

  defp upgrade(pid, uri, route, credential) do
    result =
      try do
        with {:ok, :http} <- :gun.await_up(pid, 5_000),
             ref =
               :gun.ws_upgrade(
                 pid,
                 String.trim_trailing(uri.path || "", "/") <> "/api/device/v1/" <> route,
                 [{"authorization", "Bearer " <> credential}]
               ),
             {:upgrade, ["websocket"], _} <- :gun.await(pid, ref, 5_000) do
          {:ok, {pid, ref}}
        else
          _ -> {:error, :upgrade_failed}
        end
      catch
        :exit, _ -> {:error, :disconnected}
      end

    if match?({:error, _}, result), do: :gun.close(pid)
    result
  end

  def send_json(socket, type, body) do
    with {:ok, bytes} <- Control.encode(type, body), do: send_frame(socket, {:text, bytes})
  end

  def send_frame({pid, ref}, {:binary, bytes})
      when is_binary(bytes) and byte_size(bytes) <= 65_584,
      do: :gun.ws_send(pid, ref, {:binary, bytes})

  def send_frame({pid, ref}, {:text, bytes}) when is_binary(bytes) and byte_size(bytes) <= 16_384,
    do: :gun.ws_send(pid, ref, {:text, bytes})

  def send_frame(_, _), do: {:error, :message_limit}

  def recv({pid, ref}, timeout \\ 6_000) do
    case :gun.await(pid, ref, timeout) do
      {:ws, {:text, "acquisition_request_denied"}} -> {:error, :denied}
      {:ws, {:close, 1008, _}} -> {:error, :denied}
      {:ws, {:text, bytes}} when byte_size(bytes) <= 16_384 -> Control.decode(bytes, @replies)
      {:error, :timeout} -> {:error, :timeout}
      _ -> {:error, :disconnected}
    end
  catch
    :exit, _ -> {:error, :disconnected}
  end

  def recv_nowait(socket), do: recv(socket, 0)

  def request(socket, type, body \\ %{}, timeout \\ 6_000) do
    operation = Map.get(body, "operation_id", operation_id())
    fields = Map.put(body, "operation_id", operation)

    with :ok <- send_json(socket, type, fields),
         {:ok, reply} <- recv(socket, timeout),
         true <- reply["operation_id"] == operation do
      {:ok, reply}
    else
      false -> {:error, :stale_operation}
      error -> error
    end
  end

  def operation_id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  def close({pid, _}), do: :gun.close(pid)

  defp regular_file(path, limit) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size >= 1 and size <= limit -> :ok
      _ -> {:error, :invalid_file}
    end
  end

  defp trust_file(nil), do: :ok

  defp trust_file(path) when is_binary(path) do
    if Path.type(path) == :absolute,
      do: regular_file(path, 4_194_304),
      else: {:error, :invalid_ca}
  end

  defp trust_file(_), do: {:error, :invalid_ca}
end
