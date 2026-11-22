defmodule MedFabric.ExamWeb.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  alias MedFabric.Exam

  pipeline :browser do
    plug(:accepts, ["html", "wav"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {MedFabric.ExamWeb.Layout, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:authorize_lab)
  end

  scope "/" do
    pipe_through(:browser)

    live("/encounters/:encounter_id", MedFabric.ExamWeb.ExamLive, :show)
    match(:get, "/encounters/:encounter_id/recording", __MODULE__.Recording, [])
  end

  defmodule Recording do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      config = Exam.lab()
      store = MedFabric.Store.Postgres

      with {:ok, %{metadata: m}} <- store.fetch(store, Exam.key(config)),
           {:ok, bytes} <- store.bytes(config.artifact_dir, m) do
        conn |> put_resp_content_type("audio/wav") |> send_resp(200, bytes)
      else
        _ -> send_resp(conn, 404, "Recording unavailable")
      end
    end
  end

  defp authorize_lab(conn, _opts) do
    conn = fetch_query_params(conn)

    encounter_id = conn.path_params["encounter_id"]

    case Application.get_env(:mf_exam, :lab) do
      %{encounter_id: ^encounter_id, access_key: access_key} ->
        id = encounter_id

        cond do
          get_session(conn, :lab_encounter) == id ->
            conn

          Plug.Crypto.secure_compare(
            if(is_binary(conn.query_params["key"]), do: conn.query_params["key"], else: ""),
            access_key
          ) ->
            conn
            |> configure_session(renew: true)
            |> put_session(:lab_encounter, id)
            |> put_resp_header("location", "/encounters/#{id}")
            |> send_resp(303, "")
            |> halt()

          true ->
            conn |> send_resp(403, "Exam access required") |> halt()
        end

      _ ->
        conn |> send_resp(404, "Encounter unavailable") |> halt()
    end
  end
end
