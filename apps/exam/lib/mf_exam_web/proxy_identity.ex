defmodule MedFabric.ExamWeb.ProxyIdentity do
  @moduledoc false

  def actor(headers, secret) when is_binary(secret) do
    with [token] <- values(headers, "x-exam-proxy-token"),
         true <- Plug.Crypto.secure_compare(token, secret),
         [actor] when actor != "" <- values(headers, "x-exam-actor") do
      {:ok, actor}
    else
      _ -> :error
    end
  end

  def matches?(_headers, _actor, %{local?: true}), do: true
  def matches?(headers, expected, %{proxy_secret: secret}), do: actor(headers, secret) == {:ok, expected}

  defp values(headers, key), do: for({^key, value} <- headers, do: value)
end
