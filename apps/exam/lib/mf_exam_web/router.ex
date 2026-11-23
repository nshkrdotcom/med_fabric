defmodule MedFabric.ExamWeb.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  alias MedFabric.Exam
  alias MedFabric.Store.{Postgres, Records}

  pipeline :session do
    plug(:fetch_session)
  end

  pipeline :browser do
    plug(:accepts, ["html", "wav"])
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {MedFabric.ExamWeb.Layout, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:authorize_exam)
  end

  scope "/" do
    pipe_through([:session, :browser])

    live("/encounters/:encounter_id", MedFabric.ExamWeb.ExamLive, :show)
    match(:get, "/encounters/:encounter_id/recordings/:acquisition", __MODULE__.Recording, [])
  end

  scope "/" do
    pipe_through(:session)
    match(:get, "/pcm", __MODULE__.PCM, [])
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
           {:ok, rows} <- Records.list(Postgres, conn.path_params["encounter_id"]),
           %{evidence: evidence} <- Enum.find(rows, &(&1.id == conn.path_params["acquisition"])),
           {:ok, bytes} <- Exam.artifact(Exam.lab().artifact_dir, evidence) do
        conn |> put_resp_content_type("audio/wav") |> send_resp(200, bytes)
      else
        _ -> send_resp(conn, 404, "Recording unavailable")
      end
    end
  end

  defp authorize_exam(conn, _) do
    conn = fetch_query_params(conn)
    id = conn.path_params["encounter_id"]

    case Application.get_env(:mf_exam, :lab) do
      %{encounter_id: ^id} = config ->
        authorize_member(conn, config)

      _ ->
        conn |> send_resp(404, "Encounter unavailable") |> halt()
    end
  end

  defp authorize_member(conn, config) do
    id = config.encounter_id
    actor = get_session(conn, :exam_actor)
    role = get_session(conn, :exam_role)
    key = conn.query_params["key"]

    cond do
      get_session(conn, :lab_encounter) == id and member?(id, actor, role) ->
        conn

      valid_key?(key, config.patient_key) ->
        grant(conn, id, config.patient_actor, "patient")

      valid_key?(key, config.clinician_key) ->
        grant(conn, id, config.clinician_actor, "clinician")

      true ->
        conn |> send_resp(403, "Exam access required") |> halt()
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
