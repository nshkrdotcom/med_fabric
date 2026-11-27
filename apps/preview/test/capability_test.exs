defmodule MedFabric.Preview.CapabilityTest do
  use ExUnit.Case, async: true
  alias MedFabric.Preview.Capability
  @secret String.duplicate("s", 32)

  test "authority starts at Exam check and delayed receipt subtracts verified clock error" do
    claims = claims(10_000, 35_000)
    token = sign(claims)

    assert {:ok, grant} =
             Capability.verify(token, "acq", @secret,
               now_ms: 20_000,
               mono_ms: 100,
               clock_error_ms: 2_000
             )

    assert grant.deadline == 13_100
    assert Capability.current?(grant, 13_099, 32_999)
    refute Capability.current?(grant, 13_100, 33_000)

    assert {:error, _} =
             Capability.verify(token, "acq", @secret,
               now_ms: 33_000,
               mono_ms: 100,
               clock_error_ms: 2_000
             )
  end

  test "wrong scope malformed duplicate JSON and excessive clock/lifetime fail before allocation" do
    for claims <- [
          Map.put(claims(10_000, 35_000), "purpose", "record"),
          claims(10_000, 40_001),
          Map.delete(claims(10_000, 35_000), "viewer_session"),
          Map.put(claims(10_000, 35_000), "generation", "01")
        ] do
      assert {:error, _} =
               Capability.verify(sign(claims), "acq", @secret,
                 now_ms: 12_000,
                 mono_ms: 0,
                 clock_error_ms: 2_000
               )
    end

    assert {:error, _} =
             Capability.verify(sign(claims(10_000, 35_000)), "other", @secret,
               now_ms: 12_000,
               mono_ms: 0,
               clock_error_ms: 2_000
             )

    assert {:error, _} =
             Capability.verify(sign(claims(10_000, 35_000)), "acq", @secret,
               now_ms: 12_000,
               mono_ms: 0,
               clock_error_ms: 2_001
             )

    assert {:error, _} =
             Capability.verify("not-a-token", "acq", @secret,
               now_ms: 12_000,
               mono_ms: 0,
               clock_error_ms: 0
             )
  end

  test "same token cannot renew and replacement preserves viewer identity" do
    {:ok, old} =
      Capability.verify(sign(claims(10_000, 35_000)), "acq", @secret,
        now_ms: 12_000,
        mono_ms: 100,
        clock_error_ms: 2_000
      )

    assert {:error, :not_fresh} = Capability.renew(old, old)
    newer = claims(15_000, 40_000) |> Map.put("nonce", "next")

    {:ok, fresh} =
      Capability.verify(sign(newer), "acq", @secret,
        now_ms: 16_000,
        mono_ms: 4_100,
        clock_error_ms: 2_000
      )

    assert {:ok, ^fresh} = Capability.renew(old, fresh)

    {:ok, foreign} =
      Capability.verify(sign(Map.put(newer, "viewer", "other")), "acq", @secret,
        now_ms: 16_000,
        mono_ms: 4_100,
        clock_error_ms: 2_000
      )

    assert {:error, :wrong_owner} = Capability.renew(old, foreign)
  end

  test "wall clock discontinuity invalidates an unexpired monotonic grant" do
    {:ok, grant} =
      Capability.verify(sign(claims(10_000, 35_000)), "acq", @secret,
        now_ms: 12_000,
        mono_ms: 100,
        clock_error_ms: 2_000
      )

    refute Capability.current?(grant, 200, 9_000)
    refute Capability.current?(grant, 200, 15_000)
  end

  defp claims(first, last),
    do: %{
      "purpose" => "monitor",
      "acquisition" => "acq",
      "source_kind" => "device",
      "profile" => "paired_exam",
      "generation" => "1",
      "source_epoch" => "0",
      "descriptor_ref" => String.duplicate("a", 64),
      "viewer" => "actor",
      "viewer_session" => "session",
      "issued_at_ms" => to_string(first),
      "expires_at_ms" => to_string(last),
      "nonce" => "nonce"
    }

  defp sign(claims) do
    bytes = MedEx.CanonicalJSON.encode(claims)

    Base.url_encode64(bytes, padding: false) <>
      "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, @secret, bytes), padding: false)
  end
end
