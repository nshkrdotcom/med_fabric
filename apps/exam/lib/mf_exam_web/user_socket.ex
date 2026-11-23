defmodule MedFabric.ExamWeb.UserSocket do
  @moduledoc false
  use Phoenix.Socket

  alias MedFabric.ExamWeb.Endpoint
  alias MedFabric.Store.{Postgres, Records}

  channel("signaling:*", MedFabric.ExamWeb.SignalingChannel)
  channel("talkback:*", MedFabric.ExamWeb.TalkbackChannel)

  @impl true
  def connect(%{"token" => token}, socket, info) when is_binary(token) do
    case Phoenix.Token.verify(Endpoint, "exam-preview", token, max_age: 3600) do
      {:ok, {encounter_id, actor, role}} when role in [:patient, :clinician] ->
        if MedFabric.ExamWeb.ProxyIdentity.matches?(
             info[:x_headers] || [],
             actor,
             MedFabric.Exam.lab()
           ) and
             Records.member?(Postgres, encounter_id, actor, role) do
          {:ok, assign(socket, encounter_id: encounter_id, actor: actor, role: role)}
        else
          :error
        end

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _info), do: :error

  @impl true
  def id(_socket), do: nil
end
