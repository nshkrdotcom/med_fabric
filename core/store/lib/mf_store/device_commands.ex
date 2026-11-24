defmodule MedFabric.Store.DeviceCommands do
  @moduledoc "Persistent command intent, observed results and historical uncertainty."
  alias MedFabric.Store.DeviceSessions, as: S
  alias MedFabric.Store.Postgres

  def request(enc, id, actor, gain) when gain in ["unity", "half"] do
    Postgrex.transaction(Postgres, fn tx ->
      S.rows(tx, "SELECT pg_advisory_xact_lock(hashtextextended($1,73160650))", [id])

      case S.rows(
             tx,
             "SELECT s.boot FROM device_sessions s JOIN encounters e ON e.id=s.encounter_id WHERE s.id=$1 AND e.id=$2 AND e.clinician_actor=$3 AND e.closed_at IS NULL AND s.phase='capturing' AND s.profile='paired_exam' FOR SHARE OF s,e",
             [id, enc, actor]
           ) do
        [[boot]] ->
          request_command(tx, id, actor, boot, gain)

        _ ->
          S.abort(tx, :unauthorized)
      end
    end)
  end

  defp request_command(tx, id, actor, boot, gain) do
    if S.rows(
         tx,
         "SELECT id FROM device_commands WHERE acquisition_id=$1 AND state IN ('requested','dispatching','outcome_unknown')",
         [id]
       ) != [], do: S.abort(tx, :reconciliation_required)

    watermarks =
      Map.new(
        S.rows(
          tx,
          "SELECT DISTINCT ON(stream) stream,coalesce(receipt->>'durable_sample','0') FROM stream_attempts WHERE acquisition_id=$1 ORDER BY stream,generation DESC",
          [id]
        ),
        fn [s, n] -> {s, n} end
      )

    epoch =
      case S.rows(
             tx,
             "SELECT result->>'epoch' FROM device_commands WHERE acquisition_id=$1 AND state IN ('applied','reconciled') ORDER BY updated_at DESC LIMIT 1",
             [id]
           ) do
        [[n]] -> n
        [] -> "0"
      end

    cmd = %{
      "id" => S.nonce(),
      "actor" => actor,
      "boot" => boot,
      "op" => "set_monitor_gain",
      "target" => "handheld_monitor",
      "expected_epoch" => epoch,
      "gain" => gain,
      "watermarks" => watermarks
    }

    hash =
      S.hash(
        "monitor-command-v1" <>
          <<0>> <> :erlang.term_to_binary(Enum.sort(cmd), [:deterministic])
      )

    S.rows(
      tx,
      "INSERT INTO device_commands(id,acquisition_id,fingerprint,request,state) VALUES($1,$2,$3,$4,'requested')",
      [cmd["id"], id, hash, cmd]
    )

    S.fact(tx, id, "command_requested", Map.put(cmd, "fingerprint", hash))
    :ok
  end

  def poll(bind) do
    S.scoped(bind, fn tx, _ ->
      case S.rows(
             tx,
             "SELECT id,fingerprint,request,state,updated_at < now()-interval '3 seconds' FROM device_commands WHERE acquisition_id=$1 AND state IN ('requested','dispatching','outcome_unknown') FOR UPDATE",
             [bind.id]
           ) do
        [[id, hash, req, "requested", _]] ->
          transition(tx, bind.id, id, "dispatching", %{})
          Map.merge(req, %{"type" => "command", "fingerprint" => hash})

        [[id, hash, _, "dispatching", true]] ->
          S.rows(tx, "UPDATE device_commands SET readback_count=1 WHERE id=$1", [id])
          transition(tx, bind.id, id, "outcome_unknown", %{})
          %{"type" => "state_query", "id" => id, "fingerprint" => hash}

        [[id, hash, _, "outcome_unknown", _]] ->
          retry_readback(tx, id, hash)

        _ ->
          %{"type" => "heartbeat"}
      end
    end)
  end

  defp retry_readback(tx, id, hash) do
    case S.rows(
           tx,
           "UPDATE device_commands SET readback_count=readback_count+1,updated_at=now() WHERE id=$1 AND readback_count<3 AND updated_at<clock_timestamp()-(CASE readback_count WHEN 1 THEN interval '500 milliseconds' ELSE interval '1 second' END) RETURNING id",
           [id]
         ) do
      [[^id]] -> %{"type" => "state_query", "id" => id, "fingerprint" => hash}
      _ -> %{"type" => "heartbeat"}
    end
  end

  def result(
        bind,
        %{"id" => id, "fingerprint" => hash, "boot" => boot, "status" => status} = result
      )
      when status in ["applied", "rejected", "reconciled"] do
    S.scoped(bind, fn tx, s ->
      case S.rows(
             tx,
             "SELECT state,result,request FROM device_commands WHERE acquisition_id=$1 AND id=$2 AND fingerprint=$3 FOR UPDATE",
             [bind.id, id, hash]
           ) do
        [[^status, ^result, _]] ->
          :ok

        [[state, _, request]]
        when boot == s.boot and state in ["dispatching", "outcome_unknown"] ->
          validate_result!(tx, status, state, request, result)
          transition(tx, bind.id, id, status, result)
          :ok

        _ ->
          S.abort(tx, :command_conflict)
      end
    end)
  end

  defp validate_result!(tx, status, state, request, result) do
    expected = String.to_integer(request["expected_epoch"])
    epoch = parse_epoch(result["epoch"])

    unless result_matches?(status, state, request, result, expected, epoch),
      do: S.abort(tx, :invalid_result)
  end

  defp result_matches?("applied", _state, request, result, expected, epoch) do
    result["gain"] == request["gain"] and epoch == expected + 1 and
      (is_nil(result["first_sample"]) or decimal_counter?(result["first_sample"]))
  end

  defp result_matches?("reconciled", state, _request, result, expected, epoch) do
    state == "outcome_unknown" and result["gain"] in ["half", "unity"] and
      is_integer(epoch) and epoch >= expected and is_nil(result["first_sample"])
  end

  defp result_matches?("rejected", _state, _request, _result, _expected, _epoch), do: true

  def close_pending(tx, id) do
    for [command, state] <-
          S.rows(
            tx,
            "SELECT id,state FROM device_commands WHERE acquisition_id=$1 AND state IN ('requested','dispatching') FOR UPDATE",
            [id]
          ) do
      if state == "requested" do
        transition(tx, id, command, "cancelled_before_dispatch", %{"reason" => "collection_ended"})
      else
        transition(tx, id, command, "outcome_unknown", %{
          "reason" => "collection_ended_without_result"
        })
      end
    end

    :ok
  end

  defp decimal_counter?(s), do: is_binary(s) and Regex.match?(~r/\A(0|[1-9][0-9]{0,18})\z/, s)

  defp parse_epoch(s) do
    if decimal_counter?(s) do
      n = String.to_integer(s)
      if n <= 0xFFFFFFFE, do: n
    end
  end

  defp transition(tx, acq, id, state, result) do
    S.rows(tx, "UPDATE device_commands SET state=$2,result=$3,updated_at=now() WHERE id=$1", [
      id,
      state,
      result
    ])

    S.fact(tx, acq, "command_" <> state, Map.put(result, "id", id))
  end
end
