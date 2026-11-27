defmodule MedFabric.Preview.Capability do
  @moduledoc "Purpose-bound Exam authority. Deadlines are conservative local monotonic values."
  alias MedEx.{CanonicalJSON, ContractRules}
  alias MedEx.Wire.Control

  @keys ~w(purpose acquisition source_kind profile generation source_epoch descriptor_ref viewer viewer_session issued_at_ms expires_at_ms nonce)
  @enforce_keys [
    :claims,
    :issued,
    :expires,
    :deadline,
    :received_wall,
    :received_mono,
    :clock_error
  ]
  defstruct @enforce_keys

  def verify(token, acquisition, secret, opts)
      when is_binary(token) and byte_size(token) <= 4096 and is_binary(secret) and
             byte_size(secret) in 32..4096 do
    now = Keyword.fetch!(opts, :now_ms)
    mono = Keyword.fetch!(opts, :mono_ms)
    error = Keyword.fetch!(opts, :clock_error_ms)

    with true <- is_integer(error) and error in 0..2000,
         [body, signature] <- String.split(token, "."),
         {:ok, raw} <- Base.url_decode64(body, padding: false),
         true <- byte_size(raw) <= 2048,
         {:ok, mac} <- Base.url_decode64(signature, padding: false),
         true <- byte_size(mac) == 32,
         true <- Plug.Crypto.secure_compare(mac, :crypto.mac(:hmac, :sha256, secret, raw)),
         {:ok, claims} when is_map(claims) <- CanonicalJSON.decode(raw),
         true <- Enum.sort(Map.keys(claims)) == Enum.sort(@keys),
         true <- valid_scope?(claims, acquisition),
         {:ok, generation} <- Control.uint64(claims["generation"]),
         true <- generation > 0 and generation <= 0x7FFFFFFFFFFFFFFF,
         {:ok, epoch} <- Control.uint64(claims["source_epoch"]),
         true <- epoch <= 0xFFFFFFFF,
         {:ok, issued} <- Control.uint64(claims["issued_at_ms"]),
         {:ok, expires} <- Control.uint64(claims["expires_at_ms"]),
         true <- issued <= now + error and expires > issued and expires - issued <= 25_000,
         true <- expires <= 9_007_199_254_740_991 and expires - now - error > 0 do
      {:ok,
       %__MODULE__{
         claims: claims,
         issued: issued,
         expires: expires,
         deadline: mono + expires - now - error,
         received_wall: now,
         received_mono: mono,
         clock_error: error
       }}
    else
      _ -> {:error, :denied}
    end
  end

  def verify(_, _, _, _), do: {:error, :denied}

  def current?(%__MODULE__{} = grant, mono, wall) when is_integer(mono) and is_integer(wall) do
    mono < grant.deadline and mono >= grant.received_mono and
      abs(wall - grant.received_wall - (mono - grant.received_mono)) <= grant.clock_error
  end

  def current?(_, _, _), do: false

  def key(%__MODULE__{claims: c}), do: {c["acquisition"], c["viewer"], c["viewer_session"]}

  def source(%__MODULE__{claims: c}),
    do: Map.take(c, ~w(acquisition source_kind profile generation source_epoch descriptor_ref))

  def renew(%__MODULE__{} = old, %__MODULE__{} = fresh) do
    cond do
      key(old) != key(fresh) or source(old) != source(fresh) ->
        {:error, :wrong_owner}

      fresh.issued <= old.issued or fresh.claims["nonce"] == old.claims["nonce"] ->
        {:error, :not_fresh}

      fresh.deadline <= old.deadline ->
        {:error, :not_fresh}

      true ->
        {:ok, fresh}
    end
  end

  defp valid_scope?(c, id) do
    c["purpose"] == "monitor" and c["acquisition"] == id and
      c["source_kind"] in ["device", "browser"] and
      ((c["source_kind"] == "device" and c["profile"] == "paired_exam") or
         (c["source_kind"] == "browser" and c["profile"] == "browser_microphone")) and
      Enum.all?(~w(acquisition viewer viewer_session nonce), &ContractRules.id?(c[&1])) and
      is_binary(c["descriptor_ref"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, c["descriptor_ref"])
  end
end
