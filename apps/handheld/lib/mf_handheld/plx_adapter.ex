defmodule MedFabric.Handheld.PLXAdapter do
  @moduledoc """
  Handheld simulated-peripheral adapter, not a generic MedEx API or BLE stack.
  Parses PLXS 1.0.1 sections 3.1, 3.3 and 5.1; PLXP 5.4/5.6 require ignoring RFU bits.
  https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/PLXS_v1.0.1/out/en/index-en.html
  Finite SFLOAT is {:finite, mantissa, base-10 exponent}; no rounding or clinical validation.
  Source-local time has no inferred timezone/accuracy. Raw bytes retain all source facts.
  Caller reconciles features with indications and supplies identity, timing trust and policy.
  """
  import Bitwise

  @special %{
    0x07FE => :positive_infinity,
    0x07FF => :nan,
    0x0800 => :not_at_resolution,
    0x0801 => :reserved,
    0x0802 => :negative_infinity
  }
  @features [
    :measurement_status,
    :device_status,
    :storage,
    :timestamp,
    :fast,
    :slow,
    :pulse_amplitude_index,
    :multiple_bonds
  ]
  @measurement [
    :ongoing,
    :early_estimate,
    :validated,
    :fully_qualified,
    :stored,
    :demonstration,
    :testing,
    :calibrating,
    :unavailable,
    :questionable,
    :invalid
  ]
  @device [
    :display_update,
    :equipment_fault,
    :processing_irregular,
    :inadequate_signal,
    :poor_signal,
    :low_perfusion,
    :erratic_signal,
    :non_pulsatile,
    :questionable_pulse,
    :analyzing,
    :interference,
    :sensor_off_user,
    :unknown_sensor,
    :sensor_displaced,
    :sensor_fault,
    :sensor_disconnected
  ]

  def spot_check(<<flags, spo2::binary-size(2), pr::binary-size(2), rest::binary>> = raw) do
    with {:ok, ts, r1} <- take(rest, flags, 0, 7),
         {:ok, ms, r2} <- take(r1, flags, 1, 2),
         {:ok, ds, r3} <- take(r2, flags, 2, 3),
         {:ok, pai, <<>>} <- take(r3, flags, 3, 2) do
      {:ok,
       %{
         raw: raw,
         flags: flags,
         spo2: sfloat(spo2),
         pulse_rate: sfloat(pr),
         source_time: source_time(ts, flags),
         measurement_status: status(ms, @measurement, 5),
         device_status: status(ds, @device, 0),
         pulse_amplitude_index: sfloat(pai)
       }}
    else
      _ -> {:error, :invalid_length}
    end
  end

  def spot_check(_), do: {:error, :invalid_length}

  def continuous(<<flags, s::binary-size(2), p::binary-size(2), rest::binary>> = raw) do
    with {:ok, fast, a} <- take(rest, flags, 0, 4),
         {:ok, slow, b} <- take(a, flags, 1, 4),
         {:ok, ms, c} <- take(b, flags, 2, 2),
         {:ok, ds, d} <- take(c, flags, 3, 3),
         {:ok, pai, <<>>} <- take(d, flags, 4, 2) do
      {:ok,
       %{
         raw: raw,
         flags: flags,
         spo2: sfloat(s),
         pulse_rate: sfloat(p),
         fast: pair(fast),
         slow: pair(slow),
         measurement_status: status(ms, @measurement, 5),
         device_status: status(ds, @device, 0),
         pulse_amplitude_index: sfloat(pai)
       }}
    else
      _ -> {:error, :invalid_length}
    end
  end

  def continuous(_), do: {:error, :invalid_length}
  defp pair(nil), do: nil
  defp pair(<<a::binary-size(2), b::binary-size(2)>>), do: {sfloat(a), sfloat(b)}

  def features(<<flags::little-16, rest::binary>> = raw) do
    with {:ok, ms, r1} <- take(rest, flags, 0, 2),
         {:ok, ds, <<>>} <- take(r1, flags, 1, 3) do
      {:ok,
       %{
         raw: raw,
         flags: flags,
         supported: set_bits(flags, @features, 0),
         measurement_status: status(ms, @measurement, 5),
         device_status: status(ds, @device, 0)
       }}
    else
      _ -> {:error, :invalid_length}
    end
  end

  def features(_), do: {:error, :invalid_length}

  defp take(data, flags, bit, _size) when (flags &&& 1 <<< bit) == 0, do: {:ok, nil, data}

  defp take(data, _flags, _bit, size) when byte_size(data) >= size do
    <<field::binary-size(^size), rest::binary>> = data
    {:ok, field, rest}
  end

  defp take(_, _, _, _), do: {:error, :invalid_length}

  defp sfloat(nil), do: nil

  defp sfloat(<<word::little-16>>) do
    case @special[word] do
      nil -> {:finite, signed(word &&& 0xFFF, 12), signed(word >>> 12, 4)}
      name -> {:special, name}
    end
  end

  defp signed(value, bits) when value >= 1 <<< (bits - 1), do: value - (1 <<< bits)
  defp signed(value, _bits), do: value

  defp status(nil, _, _), do: nil

  defp status(bytes, names, offset) do
    value = :binary.decode_unsigned(bytes, :little)
    %{raw: value, set: set_bits(value, names, offset)}
  end

  defp set_bits(value, names, offset) do
    for {name, bit} <- Enum.with_index(names, offset), (value &&& 1 <<< bit) != 0, do: name
  end

  defp source_time(nil, _), do: :unknown
  defp source_time(_, flags) when (flags &&& 0x10) != 0, do: :unknown

  defp source_time(<<y::little-16, m, d, h, min, s>>, _) do
    with true <- y in 1582..9999,
         {:ok, _} <- Date.new(y, m, d),
         {:ok, _} <- Time.new(h, min, s) do
      {:device_local, {y, m, d, h, min, s}}
    else
      _ -> :unknown
    end
  end
end
