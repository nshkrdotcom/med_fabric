defmodule MedFabric.ExamWeb.BrowserStreamSocket do
  @moduledoc "Thin authenticated patient-session edge to the common source-neutral acquisition socket."
  import Plug.Conn
  alias MedFabric.Exam
  alias MedFabric.Store.Encounters
  def init(opts), do: opts

  def call(conn, _) do
    conn = fetch_query_params(conn)
    actor = get_session(conn, :exam_actor)
    enc = conn.path_params["encounter_id"]
    session = get_session(conn, :exam_session)
    token = conn.query_params["token"]
    context = Exam.context()
    origin = Exam.lab().public_origin

    with "patient" <- get_session(conn, :exam_role),
         [^origin] <- get_req_header(conn, "origin"),
         {:ok, {^session, ^enc, ^actor, id, page}} <-
           Phoenix.Token.verify(MedFabric.ExamWeb.Endpoint, "browser-acquisition", token,
             max_age: 60
           ),
         true <- MedFabric.ExamWeb.ProxyIdentity.matches?(conn.req_headers, actor, Exam.lab()),
         true <- Encounters.session_authorized?(context.db, session, enc, actor, :patient) do
      MedFabric.ExamWeb.AcquisitionSocket.upgrade(
        conn,
        context,
        %{
          kind: :browser,
          id: actor,
          session: session,
          encounter: enc,
          acquisition: id,
          page: page
        },
        :browser
      )
    else
      _ -> send_resp(conn, 403, "Patient acquisition authorization required")
    end
  end
end
