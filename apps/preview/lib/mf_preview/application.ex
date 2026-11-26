defmodule MedFabric.Preview.Application do
  @moduledoc "Starts the loopback HTTP listener and supervises preview peers."

  use Application

  def start(_, _) do
    config = Application.fetch_env!(:mf_preview, :listen)
    :ets.new(:mf_preview_feed, [:named_table, :set, :public, write_concurrency: true])

    Supervisor.start_link(
      [
        {Registry, keys: :unique, name: MedFabric.Preview.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: MedFabric.Preview.Peers},
        {Bandit, plug: MedFabric.Preview.Endpoint, ip: {127, 0, 0, 1}, port: config[:port]}
      ],
      strategy: :one_for_one
    )
  end
end

defmodule MedFabric.Preview.Endpoint do
  import Plug.Conn

  alias MedEx.Wire.FrameV1
  alias MedFabric.Preview.Peer

  def init(o), do: o

  def call(c, _) do
    secret = Application.fetch_env!(:mf_preview, :listen)[:secret]

    with ["Bearer " <> token] <- get_req_header(c, "authorization"),
         true <- Plug.Crypto.secure_compare(token, secret),
         [id] <- get_req_header(c, "x-acquisition"),
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{1,96}\z/, id),
         {:ok, bytes, c} <- read_body(c, length: 65_584, read_length: 65_584, read_timeout: 1000),
         {:ok, result} <- dispatch(c.method, c.path_info, id, bytes, secret) do
      c |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(result))
    else
      _ -> send_resp(c, 403, "Denied")
    end
  end

  defp dispatch("POST", ["feed"], id, raw, _) do
    with {:ok, %{stream_number: 3, sample_count: 960, payload: pcm} = f} <-
           FrameV1.decode(raw),
         true <- byte_size(pcm) == 1920 do
      if Registry.lookup(MedFabric.Preview.Registry, id) != [],
        do: :ets.insert(:mf_preview_feed, {id, System.monotonic_time(:millisecond), f})

      {:ok, %{"credit" => 1}}
    else
      _ -> {:error, :invalid_monitor_frame}
    end
  end

  defp dispatch("POST", [op], id, bytes, secret) when op in ["offer", "close", "status"] do
    with {:ok, m} <- JSON.decode(bytes),
         [body, signature] <- String.split(m["token"] || "", ".", parts: 2),
         {:ok, payload} <- Base.url_decode64(body, padding: false),
         {:ok, mac} <- Base.url_decode64(signature, padding: false),
         true <- Plug.Crypto.secure_compare(mac, :crypto.mac(:hmac, :sha256, secret, payload)),
         {:ok, %{"acquisition" => ^id, "viewer" => actor, "exp" => exp}} <- JSON.decode(payload),
         true <- exp >= System.system_time(:second) do
      Peer.action(id, actor, op, m)
    else
      _ -> {:error, :denied}
    end
  end

  defp dispatch(_, _, _, _, _), do: {:error, :unsupported}
end

defmodule MedFabric.Preview.Peer do
  @moduledoc "Manages WebRTC signaling and live Opus audio for one acquisition."

  use GenServer, restart: :temporary

  alias MedEx.{Opus, Preview}

  def start_link(id),
    do:
      GenServer.start_link(__MODULE__, id,
        name: {:via, Registry, {MedFabric.Preview.Registry, id}}
      )

  def action(id, actor, op, m) do
    pid =
      case Registry.lookup(MedFabric.Preview.Registry, id) do
        [{p, _}] ->
          p

        [] when op == "offer" ->
          case DynamicSupervisor.start_child(MedFabric.Preview.Peers, {__MODULE__, id}) do
            {:ok, p} -> p
            {:error, {:already_started, p}} -> p
          end

        [] ->
          nil
      end

    if pid,
      do: GenServer.call(pid, {op, actor, m}, 8000),
      else: {:ok, %{"state" => "disconnected"}}
  end

  def init(id) do
    {:ok, encoder} = Opus.Provider.start_link(owner: self())
    Process.send_after(self(), :feed, 20)

    {:ok,
     %{
       id: id,
       encoder: encoder,
       encoder_ref: Process.monitor(encoder),
       peer: nil,
       owner: nil,
       status: "disconnected",
       seq: 0,
       start: nil,
       session: make_ref(),
       touched: System.monotonic_time(:second)
     }}
  end

  def handle_call({"offer", actor, %{"sdp" => sdp, "ice" => ice}}, _, s)
      when byte_size(sdp) <= 32_768 do
    if s.peer, do: Preview.close(s.peer)
    policy = if ice["iceTransportPolicy"] == "relay", do: :relay, else: :all

    case Preview.answer(sdp, ice_servers: ice["iceServers"], ice_transport_policy: policy) do
      {:ok, peer, answer} ->
        {:reply, {:ok, %{"sdp" => answer}},
         %{
           s
           | peer: peer,
             owner: actor,
             status: "connecting",
             seq: 0,
             start: nil,
             session: make_ref(),
             touched: System.monotonic_time(:second)
         }}

      _ ->
        {:stop, :normal, {:error, :negotiation_failed}, %{s | peer: nil}}
    end
  end

  def handle_call({"close", actor, _}, _, %{owner: actor} = s),
    do: {:stop, :normal, {:ok, %{"state" => "closed"}}, s}

  def handle_call({"status", actor, _}, _, %{owner: actor} = s),
    do: {:reply, {:ok, %{"state" => s.status}}, %{s | touched: System.monotonic_time(:second)}}

  def handle_call(_, _, s), do: {:reply, {:error, :denied}, s}

  def handle_info({:ex_webrtc, p, {:connection_state_change, state}}, %{peer: %{pid: p}} = s)
      when state in [:closed, :failed], do: {:stop, :normal, s}

  def handle_info({:ex_webrtc, p, {:connection_state_change, state}}, %{peer: %{pid: p}} = s),
    do: {:noreply, %{s | status: to_string(state)}}

  def handle_info({:DOWN, ref, :process, encoder, _}, %{encoder_ref: ref, encoder: encoder} = s),
    do: {:stop, :normal, s}

  def handle_info({:med_ex_encode_failed, {session, _}, _}, %{session: session} = s),
    do: {:stop, :normal, s}

  def handle_info(:feed, s) do
    result =
      case :ets.take(:mf_preview_feed, s.id) do
        [{_, at, f}] when s.status == "connected" ->
          if System.monotonic_time(:millisecond) - at <= 200,
            do: Opus.Provider.offer(s.encoder, {s.session, at}, f.first_sample, f.payload)

        _ ->
          :ok
      end

    Process.send_after(self(), :feed, 15)

    if match?({:error, {:outcome_unknown, _}}, result) or
         System.monotonic_time(:second) - s.touched > 65,
       do: {:stop, :normal, s},
       else: {:noreply, s}
  end

  def handle_info(
        {:med_ex_encoded, {ref, at}, index, data},
        %{session: ref, status: "connected"} = s
      ) do
    if System.monotonic_time(:millisecond) - at <= 200 do
      base = s.start || index
      Preview.send_opus(s.peer, data, s.seq, index - base)
      {:noreply, %{s | start: base, seq: s.seq + 1}}
    else
      {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  def terminate(_, s) do
    if s.peer, do: Preview.close(s.peer)
    :ets.delete(:mf_preview_feed, s.id)
    Registry.unregister(MedFabric.Preview.Registry, s.id)
  end
end
