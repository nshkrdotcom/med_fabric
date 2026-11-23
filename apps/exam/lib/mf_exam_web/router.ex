defmodule MedFabric.ExamWeb.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  alias MedFabric.Exam
  alias MedFabric.Exam.{Artifact, Recordings, ICE}
  alias MedFabric.Store.{Postgres, Records}

  pipeline :session do
    plug(:fetch_session)
  end

  pipeline :browser do
    plug(:accepts, ["html", "wav", "json"])
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {MedFabric.ExamWeb.Layout, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:authorize_exam)
  end

  scope "/" do
    pipe_through([:session, :browser])

    get("/encounters/:encounter_id/attempts/:acquisition", __MODULE__.State, :attempt)
    get("/encounters/:encounter_id/ice", __MODULE__.State, :ice)
    live("/encounters/:encounter_id", MedFabric.ExamWeb.ExamLive, :show)
    match(:get, "/encounters/:encounter_id/recordings/:acquisition", __MODULE__.Recording, [])
  end

  scope "/" do
    pipe_through(:session)
    match(:get, "/encounters/:encounter_id/pcm", __MODULE__.PCM, [])
  end

  defmodule PCM do
    @moduledoc false
    alias MedFabric.ExamWeb.PCMSocket
    def init(opts), do: opts
    def call(conn, opts), do: PCMSocket.upgrade(conn, opts)
  end

  defmodule Recording do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      with "clinician" <- get_session(conn, :exam_role),
           id = conn.path_params["acquisition"],
           {:ok, %{evidence: %{"kind" => "audio_pcm16_wav"} = evidence}} <-
             Records.get(Postgres, conn.path_params["encounter_id"], id) do
        Artifact.serve(conn, Exam.lab().artifact_dir, id, evidence)
      else
        _ -> send_resp(conn, 404, "Recording unavailable")
      end
    end
  end

  defmodule State do
    @moduledoc false
    import Plug.Conn
    def init(action), do: action

    def call(conn, :ice) do
      json(conn, ICE.config(get_session(conn, :exam_actor), Exam.lab().turn))
    end

    def call(conn, :attempt) do
      with "patient" <- get_session(conn, :exam_role),
           {:ok, state} <- Recordings.status(conn.path_params["encounter_id"], conn.path_params["acquisition"]) do
        json(conn, %{status: state})
      else
        _ -> send_resp(conn, 404, "Attempt unavailable")
      end
    end

    defp json(conn, data) do
      conn |> put_resp_header("cache-control", "no-store") |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(data))
    end
  end

  defp authorize_exam(conn, _) do
    conn = fetch_query_params(conn)
    id = conn.path_params["encounter_id"]

    with %{encounters: entries} = lab <- Application.get_env(:mf_exam, :lab),
         %{^id => entry} <- entries do
      authorize_member(conn, id, entry, lab)
    else
      _ -> conn |> send_resp(404, "Encounter unavailable") |> halt()
    end
  end

  defp authorize_member(conn, id, entry, lab) do
    actor = get_session(conn, :exam_actor)
    role = get_session(conn, :exam_role)
    key = conn.query_params["key"]
    local_session = get_session(conn, :lab_encounter) == id and member?(id, actor, role)

    cond do
      lab.local? && local_session -> conn
      lab.local? && valid_key?(key, entry["patient_key"]) ->
        grant(conn, id, entry["patient_actor"], "patient")
      lab.local? && valid_key?(key, entry["clinician_key"]) ->
        grant(conn, id, entry["clinician_actor"], "clinician")
      !lab.local? ->
        authorize_proxy(conn, id, entry, lab.proxy_secret, local_session)
      true -> conn |> send_resp(403, "Exam access required") |> halt()
    end
  end

  defp authorize_proxy(conn, id, entry, secret, current_session) do
    with [token] <- get_req_header(conn, "x-exam-proxy-token"),
         true <- valid_key?(token, secret),
         [actor] <- get_req_header(conn, "x-exam-actor"),
         role when role in ["patient", "clinician"] <-
           Enum.find(["patient", "clinician"], &(entry[&1 <> "_actor"] == actor)),
         true <- member?(id, actor, role) do
      if current_session and get_session(conn, :exam_actor) == actor,
        do: conn, else: grant(conn, id, actor, role)
    else
      _ -> conn |> send_resp(403, "Exam access required") |> halt()
    end
  end

  defp valid_key?(key, expected), do: is_binary(key) and Plug.Crypto.secure_compare(key, expected)

  defp member?(id, actor, "patient"), do: Records.member?(Postgres, id, actor, :patient)
  defp member?(id, actor, "clinician"), do: Records.member?(Postgres, id, actor, :clinician)
  defp member?(_, _, _), do: false

  defp grant(conn, id, actor, role) do
    conn
    |> configure_session(renew: true)
    |> put_session(:lab_encounter, id)
    |> put_session(:exam_actor, actor)
    |> put_session(:exam_role, role)
    |> put_resp_header("location", "/encounters/#{id}")
    |> send_resp(303, "")
    |> halt()
  end
end
