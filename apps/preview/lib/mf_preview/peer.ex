defmodule MedFabric.Preview.Peer do
  @moduledoc "One temporary viewer owns one encoder and one opaque RTC peer."
  use GenServer, restart: :temporary
  alias MedEx.Opus.Provider, as: Opus
  alias MedEx.RTC.Provider, as: RTC
  alias MedFabric.Preview.{Capability, Feed, Timeline}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {MedFabric.Preview.Registry, Capability.key(opts.grant)}}
    )
  end

  def action(grant, operation, body, config) do
    key = Capability.key(grant)
    token = make_ref()

    if Feed.enter(key, token) do
      try do
        with {:ok, pid} <- find_peer(grant, operation, config) do
          try do
            GenServer.call(pid, {operation, grant, body}, 8_000)
          catch
            :exit, _ ->
              # A timed-out negotiation is retired, never reused by a later request.
              Process.exit(pid, :kill)
              {:error, :media_outcome_unknown}
          end
        end
      after
        Feed.leave(key, token)
      end
    else
      {:error, :busy}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp find_peer(grant, operation, config) do
    case Feed.reserve(grant, operation == "offer") do
      {:ok, pid} ->
        {:ok, pid}

      :absent ->
        {:error, :disconnected}

      {:reserved, ticket} ->
        key = Capability.key(grant)
        opts = %{grant: grant, ticket: ticket, config: config}

        start_reserved_peer(key, ticket, opts)

      error ->
        error
    end
  end

  defp start_reserved_peer(key, ticket, opts) do
    case DynamicSupervisor.start_child(MedFabric.Preview.Peers, {__MODULE__, opts}) do
      {:ok, pid} ->
        attach_reserved_peer(key, ticket, pid)

      error ->
        Feed.release(key, ticket)
        error
    end
  end

  defp attach_reserved_peer(key, ticket, pid) do
    case Feed.attach(key, ticket, pid) do
      :ok ->
        {:ok, pid}

      error ->
        Process.exit(pid, :kill)
        Feed.release(key, ticket)
        error
    end
  end

  def init(opts) do
    Process.flag(:trap_exit, true)
    key = Capability.key(opts.grant)

    with true <- current?(opts.grant), :ok <- Feed.update(key, self(), opts.grant) do
      timer = Process.send_after(self(), :feed, 20)

      {:ok,
       %{
         key: key,
         ticket: opts.ticket,
         config: opts.config,
         grant: opts.grant,
         encoder: nil,
         encoder_ref: nil,
         peer: nil,
         peer_ref: nil,
         pending: nil,
         status: "disconnected",
         timeline: Timeline.new(),
         timer: timer,
         last_activity: System.monotonic_time(:millisecond),
         drops: 0
       }}
    else
      _ -> {:stop, :expired_authority}
    end
  end

  def handle_call({"offer", grant, %{"sdp" => sdp}}, _, state) do
    with true <- current?(state.grant) and current?(grant),
         :ok <- replacement_allowed(state.grant, grant) do
      stopped = retire_media(state)
      # Replaying an already checked token must retain its original monotonic deadline.
      grant = if state.grant.claims == grant.claims, do: state.grant, else: grant
      Feed.clear(state.key)

      case open_media(grant, sdp, stopped.config) do
        {:ok, encoder, peer, answer} ->
          next = %{
            stopped
            | grant: grant,
              encoder: encoder,
              encoder_ref: Process.monitor(encoder),
              peer: peer,
              peer_ref: RTC.peer_ref(peer),
              status: "connecting",
              timeline: Timeline.new(),
              last_activity: System.monotonic_time(:millisecond)
          }

          accept_media(state.key, grant, answer, next)

        {:error, _} ->
          {:stop, :normal, {:error, :negotiation_failed}, stopped}
      end
    else
      _ -> {:reply, {:error, :denied}, state}
    end
  end

  def handle_call({"renew", grant, _}, _, state) do
    with true <- current?(state.grant) and current?(grant),
         {:ok, fresh} <- Capability.renew(state.grant, grant),
         :ok <- Feed.update(state.key, self(), fresh) do
      {:reply, {:ok, %{"state" => state.status}}, %{state | grant: fresh}}
    else
      _ -> {:reply, {:error, :denied}, state}
    end
  end

  def handle_call({operation, grant, _}, _, state) when operation in ["status", "close"] do
    if current?(state.grant) and current?(grant) and
         Capability.key(state.grant) == Capability.key(grant) and
         Capability.source(state.grant) == Capability.source(grant) do
      if operation == "close",
        do: {:stop, :normal, {:ok, %{"state" => "closed"}}, state},
        else: {:reply, {:ok, %{"state" => state.status, "dropped_frames" => state.drops}}, state}
    else
      {:reply, {:error, :denied}, state}
    end
  end

  def handle_call(_, _, state), do: {:reply, {:error, :denied}, state}

  def handle_info(:feed, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      not current?(state.grant) ->
        {:stop, :normal, state}

      now - state.last_activity > 65_000 ->
        {:stop, :normal, state}

      true ->
        next = feed(state, now)

        case next do
          {:stop, state} -> {:stop, :normal, state}
          state -> {:noreply, %{state | timer: Process.send_after(self(), :feed, 15)}}
        end
    end
  end

  def handle_info({:med_ex_rtc, ref, status}, %{peer_ref: ref} = state)
      when status in [:closed, :failed, :disconnected], do: {:stop, :normal, state}

  def handle_info({:med_ex_rtc, ref, status}, %{peer_ref: ref} = state)
      when status in [:connecting, :connected, :new],
      do: {:noreply, %{state | status: to_string(status)}}

  def handle_info(
        {:DOWN, ref, :process, encoder, _},
        %{encoder_ref: ref, encoder: encoder} = state
      ),
      do: {:stop, :normal, %{state | encoder: nil, encoder_ref: nil}}

  def handle_info({:EXIT, encoder, _}, %{encoder: encoder} = state), do: {:stop, :normal, state}

  def handle_info({:med_ex_encode_failed, id, _}, %{pending: %{id: id}} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:med_ex_encoded, id, sample, packet},
        %{pending: %{id: id, sample: sample} = pending} = state
      ) do
    now = System.monotonic_time(:millisecond)

    cond do
      not current?(state.grant) ->
        {:stop, :normal, state}

      now - pending.at > 200 or state.status != "connected" ->
        {:noreply, %{state | pending: nil, drops: state.drops + 1}}

      true ->
        case RTC.send_opus(
               state.peer,
               packet,
               pending.plan.sequence,
               pending.plan.tick,
               state.grant.deadline
             ) do
          :ok ->
            {:noreply,
             %{
               state
               | pending: nil,
                 timeline: Timeline.submitted(pending.plan),
                 last_activity: now
             }}

          _ ->
            {:stop, :normal, state}
        end
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp accept_media(key, grant, answer, next) do
    if current?(grant) and Feed.update(key, self(), grant) == :ok do
      {:reply, {:ok, %{"sdp" => answer, "state" => "connecting"}}, next}
    else
      {:stop, :normal, {:error, :expired_authority}, next}
    end
  end

  defp feed(state, now) do
    case Feed.take(state.key) do
      {:ok, at, source, frame} -> admit_frame(state, now, at, source, frame)
      :empty -> state
    end
  end

  defp admit_frame(state, now, at, source, frame) do
    epoch = state.grant.claims["source_epoch"]

    cond do
      source != Capability.source(state.grant) ->
        %{state | drops: state.drops + 1}

      to_string(frame.source_epoch) != epoch ->
        {:stop, state}

      now - at > 200 or state.status != "connected" or state.pending != nil ->
        %{state | drops: state.drops + 1}

      not current?(state.grant) ->
        {:stop, state}

      true ->
        plan_frame(state, frame, at)
    end
  end

  defp plan_frame(state, frame, at) do
    case Timeline.plan(state.timeline, frame.first_sample, {48_000, 1}) do
      {:ok, plan} -> offer_frame(state, frame, at, plan)
      _ -> {:stop, state}
    end
  end

  defp offer_frame(state, frame, at, plan) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    case Opus.offer(state.encoder, id, frame.first_sample, frame.payload) do
      :ok ->
        %{state | pending: %{id: id, sample: frame.first_sample, plan: plan, at: at}}

      {:error, :busy} ->
        %{state | drops: state.drops + 1}

      _ ->
        {:stop, state}
    end
  end

  defp replacement_allowed(old, next) do
    cond do
      Capability.key(old) != Capability.key(next) ->
        {:error, :wrong_owner}

      old.claims == next.claims ->
        :ok

      next.issued <= old.issued ->
        {:error, :stale_authority}

      Map.take(old.claims, ~w(source_kind profile)) !=
          Map.take(next.claims, ~w(source_kind profile)) ->
        {:error, :wrong_source}

      String.to_integer(next.claims["generation"]) < String.to_integer(old.claims["generation"]) ->
        {:error, :stale_generation}

      next.claims["generation"] == old.claims["generation"] and
          Capability.source(old) != Capability.source(next) ->
        {:error, :source_conflict}

      true ->
        :ok
    end
  end

  defp open_media(grant, sdp, config) do
    if current?(grant) do
      case Opus.start_link(owner: self()) do
        {:ok, encoder} ->
          open_rtc(grant, sdp, config, encoder)

        _ ->
          {:error, :encoder_unavailable}
      end
    else
      {:error, :expired}
    end
  end

  defp open_rtc(grant, sdp, config, encoder) do
    result =
      if current?(grant),
        do:
          RTC.answer(sdp,
            owner: self(),
            ice_servers: config[:ice_servers],
            ice_transport_policy: config[:ice_transport_policy]
          ),
        else: {:error, :expired}

    case result do
      {:ok, peer, answer} ->
        {:ok, encoder, peer, answer}

      _ ->
        Opus.stop(encoder)
        {:error, :negotiation_failed}
    end
  end

  defp current?(grant),
    do:
      Capability.current?(
        grant,
        System.monotonic_time(:millisecond),
        System.system_time(:millisecond)
      )

  defp retire_media(state) do
    if state.peer, do: RTC.close(state.peer)
    if state.encoder, do: Opus.stop(state.encoder)
    if state.encoder_ref, do: Process.demonitor(state.encoder_ref, [:flush])

    %{
      state
      | peer: nil,
        peer_ref: nil,
        encoder: nil,
        encoder_ref: nil,
        pending: nil,
        status: "disconnected"
    }
  end

  def terminate(_, state) do
    Process.cancel_timer(state.timer)
    retire_media(state)
    Feed.clear(state.key)
    Feed.release(state.key, state.ticket)
    :ok
  end
end
