defmodule MedFabric.ExamWeb.UserSocket do
  @moduledoc false
  use Phoenix.Socket
  alias MedFabric.Exam
  alias MedFabric.ExamWeb.{Endpoint, ProxyIdentity}
  alias MedFabric.Store.Encounters
  channel("talkback:*", MedFabric.ExamWeb.TalkbackChannel)

  def connect(%{"token" => token}, socket, info)
      when is_binary(token) and byte_size(token) <= 4096 do
    with {:ok, {enc, actor, role, session, "talkback"}} <-
           Phoenix.Token.verify(Endpoint, "exam-talkback", token, max_age: 3600),
         true <- role in [:patient, :clinician],
         true <- ProxyIdentity.matches?(info[:x_headers] || [], actor, Exam.lab()),
         true <-
           Encounters.session_authorized?(
             Exam.context().db,
             session,
             enc,
             actor,
             role
           ) do
      {:ok, assign(socket, encounter_id: enc, actor: actor, role: role, session: session)}
    else
      _ -> :error
    end
  end

  def connect(_, _, _), do: :error
  def id(socket), do: "talkback-session:" <> socket.assigns.session
end
