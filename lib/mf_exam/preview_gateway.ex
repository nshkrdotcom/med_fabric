defmodule MedFabric.Exam.PreviewGateway do
  @moduledoc "Disposable feed. One in-flight request and one latest replacement per active source."
  use GenServer
  def start_link(sidecar), do: GenServer.start_link(__MODULE__, sidecar, name: __MODULE__)

  def init(sidecar) do
    :ets.new(__MODULE__, [:named_table, :set, :public, write_concurrency: true])
    Process.send_after(self(), :drain, 10)
    {:ok, sidecar}
  end

  def feed(id, raw) do
    case :ets.whereis(__MODULE__) do
      :undefined -> :ok
      table -> insert_latest(table, id, raw)
    end

    :ok
  end

  defp insert_latest(table, id, raw) do
    :ets.insert(table, {id, System.monotonic_time(:millisecond), raw})
  rescue
    ArgumentError -> :ok
  end

  def handle_info(:drain, sidecar) do
    for {id, _, _} <- :ets.tab2list(__MODULE__), do: drain(id, sidecar)

    Process.send_after(self(), :drain, 10)
    {:noreply, sidecar}
  end

  defp drain(id, sidecar) do
    with [{_, at, raw}] <- :ets.take(__MODULE__, id),
         true <- System.monotonic_time(:millisecond) - at <= 200 do
      request("feed", id, raw, "application/octet-stream", sidecar)
    end
  end

  def viewer(id, actor) do
    with %{secret: key} <- Application.get_env(:mf_exam, :sidecar) do
      bytes =
        JSON.encode!(%{
          "acquisition" => id,
          "viewer" => actor,
          "exp" => System.system_time(:second) + 60
        })

      Base.url_encode64(bytes, padding: false) <>
        "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, key, bytes), padding: false)
    end
  end

  def request(path, id, body, ct),
    do: request(path, id, body, ct, Application.get_env(:mf_exam, :sidecar))

  defp request(path, id, body, ct, sidecar) do
    with %{url: url, secret: key} <- sidecar,
         {:ok, %{status: 200, body: out}} <-
           Req.post(url <> "/" <> path,
             body: body,
             headers: [
               {"authorization", "Bearer " <> key},
               {"x-acquisition", id},
               {"content-type", ct}
             ],
             retry: false,
             receive_timeout: if(path == "offer", do: 8000, else: 200),
             decode_body: false
           ) do
      {:ok, out}
    else
      _ -> {:error, :preview_unavailable}
    end
  end
end

defmodule MedFabric.ExamWeb.DevicePreview do
  @moduledoc false
  import Plug.Conn
  alias MedFabric.Exam.{ICE, PreviewGateway}
  alias MedFabric.Store.{DeviceSessions, Postgres}
  def init(o), do: o

  def call(c, _) do
    p = c.path_params
    actor = get_session(c, :exam_actor)
    op = c.body_params["operation"]

    with "clinician" <- get_session(c, :exam_role),
         true <- op in ["offer", "close", "status"],
         [[_]] <-
           DeviceSessions.rows(
             Postgres,
             "SELECT s.id FROM device_sessions s JOIN encounters e ON e.id=s.encounter_id WHERE s.id=$1 AND e.id=$2 AND e.clinician_actor=$3 AND e.closed_at IS NULL AND s.phase='capturing'",
             [p["id"], p["encounter_id"], actor]
           ),
         token when is_binary(token) <- PreviewGateway.viewer(p["id"], actor),
         sdp = c.body_params["sdp"] || "",
         true <- is_binary(sdp) and byte_size(sdp) <= 32_768,
         ice = ICE.config(actor, MedFabric.Exam.lab().turn),
         {:ok, bytes} <-
           PreviewGateway.request(
             op,
             p["id"],
             JSON.encode!(%{"token" => token, "sdp" => sdp, "ice" => ice}),
             "application/json"
           ) do
      c |> put_resp_content_type("application/json") |> send_resp(200, bytes)
    else
      _ -> send_resp(c, 503, "Preview unavailable")
    end
  end
end
