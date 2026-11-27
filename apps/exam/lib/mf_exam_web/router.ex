defmodule MedFabric.ExamWeb.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router
  alias MedFabric.Exam
  alias MedFabric.ExamWeb.ProxyIdentity

  scope "/api/device/v1" do
    match(:get, "/control", MedFabric.ExamWeb.DeviceSocket, :control)
    match(:get, "/stream", MedFabric.ExamWeb.DeviceSocket, :stream)
    match(:get, "/monitor", MedFabric.ExamWeb.DeviceSocket, :monitor)
  end

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
    get("/encounters/:encounter_id/ice", __MODULE__.State, :ice)
    post("/encounters/:encounter_id/acquisitions/browser", __MODULE__.BrowserCreate, [])

    get(
      "/encounters/:encounter_id/acquisitions/browser/stream",
      MedFabric.ExamWeb.BrowserStreamSocket,
      []
    )

    get(
      "/encounters/:encounter_id/acquisitions/:id/segment/:stream/:first_sample/:sha",
      MedFabric.ExamWeb.DeviceSegment,
      []
    )

    post("/encounters/:encounter_id/acquisitions/:id/action", MedFabric.ExamWeb.DeviceAction, [])

    post(
      "/encounters/:encounter_id/observations/:id/deliver",
      MedFabric.ExamWeb.DeviceAction,
      :deliver
    )

    post(
      "/encounters/:encounter_id/acquisitions/:id/preview",
      MedFabric.ExamWeb.DevicePreview,
      []
    )

    live("/encounters/:encounter_id/devices", MedFabric.ExamWeb.DeviceLive, :show)
    live("/encounters/:encounter_id", MedFabric.ExamWeb.ExamLive, :show)
  end

  defmodule State do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, :ice) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(MedFabric.Exam.ICE.config(get_session(conn, :exam_actor), Exam.lab().turn))
      )
    end
  end

  defmodule BrowserCreate do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      actor = get_session(conn, :exam_actor)
      session = get_session(conn, :exam_session)
      enc = conn.path_params["encounter_id"]

      with "patient" <- get_session(conn, :exam_role),
           {:ok, created} <-
             MedFabric.Store.AcquisitionSessions.create_browser(
               Exam.context().db,
               enc,
               actor,
               session,
               conn.body_params["page"],
               conn.body_params["request_id"]
             ) do
        token =
          Phoenix.Token.sign(
            MedFabric.ExamWeb.Endpoint,
            "browser-acquisition",
            {session, enc, actor, created.acquisition, created.page}
          )

        body = Map.merge(created, %{stream_token: token, source_ref: actor})

        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("application/json")
        |> send_resp(201, Jason.encode!(body))
      else
        _ -> send_resp(conn, 403, "Patient acquisition creation denied")
      end
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

    current_session =
      get_session(conn, :lab_encounter) == id and role in ["patient", "clinician"] and
        MedFabric.Store.Encounters.session_authorized?(
          Exam.context().db,
          get_session(conn, :exam_session),
          id,
          actor,
          if(role == "patient", do: :patient, else: :clinician),
          :read
        )

    if lab.local? do
      authorize_local(conn, id, entry, current_session)
    else
      authorize_proxy(conn, id, entry, lab.proxy_secret, current_session)
    end
  end

  defp authorize_local(conn, _id, _entry, true), do: conn

  defp authorize_local(conn, id, entry, false) do
    key = conn.query_params["key"]

    cond do
      valid_key?(key, entry["patient_key"]) ->
        grant(conn, id, entry["patient_actor"], "patient")

      valid_key?(key, entry["clinician_key"]) ->
        grant(conn, id, entry["clinician_actor"], "clinician")

      true ->
        conn |> send_resp(403, "Exam access required") |> halt()
    end
  end

  defp authorize_proxy(conn, id, entry, secret, current_session) do
    with {:ok, actor} <- ProxyIdentity.actor(conn.req_headers, secret),
         role when role in ["patient", "clinician"] <-
           Enum.find(["patient", "clinician"], &(entry[&1 <> "_actor"] == actor)),
         true <-
           MedFabric.Store.Records.member?(
             Exam.context().db,
             id,
             actor,
             if(role == "patient", do: :patient, else: :clinician),
             :read
           ) do
      if current_session and get_session(conn, :exam_actor) == actor,
        do: conn,
        else: grant(conn, id, actor, role)
    else
      _ -> conn |> send_resp(403, "Exam access required") |> halt()
    end
  end

  defp valid_key?(key, expected), do: is_binary(key) and Plug.Crypto.secure_compare(key, expected)

  defp grant(conn, id, actor, role) do
    session = MedFabric.Store.AcquisitionSessions.nonce()

    {:ok, :ok} =
      MedFabric.Store.Encounters.browser_session(
        Exam.context().db,
        session,
        id,
        actor,
        if(role == "patient", do: :patient, else: :clinician)
      )

    conn
    |> put_session(:exam_session, session)
    |> configure_session(renew: true)
    |> put_session(:lab_encounter, id)
    |> put_session(:exam_actor, actor)
    |> put_session(:exam_role, role)
    |> put_resp_header("location", "/encounters/#{id}")
    |> send_resp(303, "")
    |> halt()
  end
end
