defmodule MedFabric.Exam.ICE do
  @moduledoc false

  # coturn REST authentication. Issue a short-lived credential per participant;
  # the static signing secret stays inside the application.
  def config(actor, %{urls: urls, secret: secret, relay?: relay?}) do
    servers =
      if urls == [] do
        []
      else
        identity = :crypto.hash(:sha256, actor) |> Base.url_encode64(padding: false)
        username = "#{System.system_time(:second) + 3600}:#{identity}"
        password = :crypto.mac(:hmac, :sha, secret, username) |> Base.encode64()
        [%{urls: urls, username: username, credential: password}]
      end

    %{iceServers: servers, iceTransportPolicy: if(relay?, do: "relay", else: "all")}
  end
end
