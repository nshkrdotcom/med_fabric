defmodule MedFabric.Preview.Endpoint do
  @moduledoc "Bounded private HTTP edge. Capability verification precedes peer allocation."
  import Plug.Conn
  alias MedEx.ContractRules
  alias MedEx.Wire.{Control, FrameV1}
  alias MedFabric.Preview.{Capability, Feed, Peer}
  def init(config), do: config

  def call(conn, config) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- byte_size(token) <= 4096 and Plug.Crypto.secure_compare(token, config[:secret]),
         [id] <- get_req_header(conn, "x-acquisition"),
         true <- ContractRules.id?(id),
         {:ok, bytes, conn} <-
           read_body(conn, length: 65_584, read_length: 65_584, read_timeout: 1_000),
         {:ok, result} <- dispatch(conn, id, bytes, config) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(result))
    else
      _ -> conn |> put_resp_header("cache-control", "no-store") |> send_resp(403, "Denied")
    end
  end

  defp dispatch(%{method: "POST", path_info: ["feed"]} = conn, id, bytes, _config) do
    with [generation] <- get_req_header(conn, "x-generation"),
         {:ok, gen} <- Control.uint64(generation),
         true <- gen in 1..0x7FFFFFFFFFFFFFFF,
         [epoch] <- get_req_header(conn, "x-source-epoch"),
         {:ok, ep} <- Control.uint64(epoch),
         [descriptor] <- get_req_header(conn, "x-descriptor-ref"),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, descriptor),
         {:ok,
          %FrameV1{stream_number: 3, source_epoch: ^ep, sample_count: 960, payload: pcm} = frame} <-
           FrameV1.decode(bytes),
         true <- byte_size(pcm) == 1920 do
      # Registry iteration is bounded by the configured peer cap; each peer keeps one slot.
      for kind <- ["device", "browser"] do
        source = %{
          "acquisition" => id,
          "source_kind" => kind,
          "profile" => if(kind == "device", do: "paired_exam", else: "browser_microphone"),
          "generation" => generation,
          "source_epoch" => epoch,
          "descriptor_ref" => descriptor
        }

        Feed.offer(source, frame)
      end

      {:ok, %{"credit" => 1}}
    else
      _ -> {:error, :invalid_monitor_frame}
    end
  end

  defp dispatch(%{method: "POST", path_info: [op]}, id, bytes, config)
       when op in ~w(offer status close renew) do
    with true <- byte_size(bytes) <= 40_960,
         {:ok, body} when is_map(body) <- decode_object(bytes),
         true <-
           Enum.sort(Map.keys(body)) == if(op == "offer", do: ["sdp", "token"], else: ["token"]),
         true <- op != "offer" or (is_binary(body["sdp"]) and byte_size(body["sdp"]) in 1..32_768),
         {:ok, grant} <-
           Capability.verify(body["token"], id, config[:secret],
             now_ms: System.system_time(:millisecond),
             mono_ms: System.monotonic_time(:millisecond),
             clock_error_ms: config[:clock_error_ms]
           ) do
      Peer.action(grant, op, body, config)
    else
      _ -> {:error, :denied}
    end
  end

  defp dispatch(_, _, _, _), do: {:error, :unsupported}

  defp decode_object(bytes) do
    decoders = [
      object_start: fn _ -> %{} end,
      object_push: fn key, value, object ->
        if Map.has_key?(object, key), do: throw(:duplicate_key)
        Map.put(object, key, value)
      end,
      object_finish: fn object, parent -> {object, parent} end
    ]

    case JSON.decode(bytes, nil, decoders) do
      {value, nil, rest} when is_map(value) ->
        if String.trim(rest) == "", do: {:ok, value}, else: {:error, :invalid_json}

      _ ->
        {:error, :invalid_json}
    end
  rescue
    JSON.DecodeError -> {:error, :invalid_json}
  catch
    :duplicate_key -> {:error, :invalid_json}
  end
end
