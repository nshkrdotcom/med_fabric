defmodule MedFabric.ExamWeb.TalkbackChannel do
  @moduledoc false
  use Phoenix.Channel

  alias MedFabric.Store.{Postgres, Records}

  @impl true
  def join(
        "talkback:" <> id,
        _,
        %{assigns: %{encounter_id: id, actor: actor, role: role}} = socket
      ) do
    if Records.member?(Postgres, id, actor, role),
      do: {:ok, socket},
      else: {:error, %{reason: "unauthorized"}}
  end

  def join(_, _, _), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_in("signal", %{"type" => type} = payload, socket)
      when type in ["ready", "offer", "answer"] do
    %{encounter_id: id, actor: actor, role: role} = socket.assigns

    if byte_size(Jason.encode!(payload)) <= 32_768 and Records.member?(Postgres, id, actor, role) do
      broadcast_from!(socket, "signal", Map.put(payload, "role", Atom.to_string(role)))
      {:noreply, socket}
    else
      {:reply, {:error, %{reason: "invalid_signal"}}, socket}
    end
  end

  def handle_in(_, _, socket), do: {:reply, :error, socket}
end
