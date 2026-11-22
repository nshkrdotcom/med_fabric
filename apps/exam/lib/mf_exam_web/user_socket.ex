defmodule MedFabric.ExamWeb.UserSocket do
  @moduledoc false
  use Phoenix.Socket

  alias MedFabric.ExamWeb.Endpoint

  channel("signaling:*", MedFabric.ExamWeb.SignalingChannel)

  @impl true
  def connect(%{"token" => token}, socket, _info) when is_binary(token) do
    case Phoenix.Token.verify(Endpoint, "exam-preview", token, max_age: 3600) do
      {:ok, encounter_id} -> {:ok, assign(socket, :encounter_id, encounter_id)}
      _ -> :error
    end
  end

  def connect(_params, _socket, _info), do: :error

  @impl true
  def id(_socket), do: nil
end
