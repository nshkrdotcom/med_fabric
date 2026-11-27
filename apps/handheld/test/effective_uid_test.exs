defmodule MedExHandheld.EffectiveUIDTest do
  use ExUnit.Case, async: true
  alias MedExHandheld.EffectiveUID

  test "Linux uses the effective UID field rather than real or filesystem UID" do
    status = "Name:\tbeam.smp\nUid:\t1000\t1001\t1002\t1003\nGid:\t1\t2\t3\t4\n"
    assert {:ok, 1001} = EffectiveUID.parse_status(status)

    assert {:ok, 1001} =
             EffectiveUID.resolve({:unix, :linux}, fn -> {:ok, status} end, fn ->
               flunk("valid procfs identity must not start an id subprocess")
             end)
  end

  test "POSIX fallback is explicit and unsupported platforms fail closed" do
    missing = fn -> {:error, :enoent} end
    fallback = fn -> {:ok, 42} end
    assert {:ok, 42} = EffectiveUID.resolve({:unix, :linux}, missing, fallback)
    assert {:ok, 42} = EffectiveUID.resolve({:unix, :darwin}, missing, fallback)
    assert {:ok, 42} = EffectiveUID.resolve({:unix, :freebsd}, missing, fallback)

    assert {:error, :unsupported_identity_platform} =
             EffectiveUID.resolve({:win32, :nt}, missing, fallback)

    for reason <- [:identity_command_unavailable, :identity_command_failed, :identity_timeout] do
      assert {:error, ^reason} =
               EffectiveUID.resolve({:unix, :linux}, missing, fn -> {:error, reason} end)
    end
  end

  test "malformed, duplicate and out-of-range identities cannot authorize ownership" do
    for bad <- ["", "-1", "+1", "01", "4294967296", "1\n2", "1\n\n", " 1", "1 ", <<255>>] do
      assert {:error, :invalid_effective_uid} = EffectiveUID.parse_output(bad)
    end

    for good <- ["0", "1000\n", "4294967295\n"] do
      assert {:ok, _} = EffectiveUID.parse_output(good)
    end

    for bad <- [
          "Uid:\t0\t1\t2\n",
          "Uid:\t0\t-1\t2\t3\n",
          "Uid:\t0\t4294967296\t2\t3\n",
          "Uid:\t0\t1\t2\t3\nUid:\t0\t1\t2\t3\n",
          "Name:\tbeam\n"
        ] do
      assert {:error, :invalid_effective_uid} = EffectiveUID.parse_status(bad)

      assert {:error, :invalid_effective_uid} =
               EffectiveUID.resolve({:unix, :linux}, fn -> {:ok, bad} end, fn ->
                 flunk("malformed identity must fail closed")
               end)
    end
  end

  test "command collection bounds output, exit status and wall time and closes its port" do
    for {body, expected} <- [
          {"import sys;sys.stdout.write('123\\n')", {:ok, 123}},
          {"import sys;sys.stdout.write('123\\n');sys.exit(2)",
           {:error, :identity_command_failed}},
          {"print('x' * 33)", {:error, :invalid_effective_uid}}
        ] do
      port = fixture_port(body)
      assert EffectiveUID.read_port(port, 1000) == expected
      assert Port.info(port) == nil
    end

    # Port.close releases the child's blocking stdin read on every POSIX host.
    port = fixture_port("import sys;sys.stdin.buffer.read()")
    start = System.monotonic_time(:millisecond)
    assert {:error, :identity_timeout} = EffectiveUID.read_port(port, 20)
    assert System.monotonic_time(:millisecond) - start < 1000
    assert Port.info(port) == nil
  end

  test "the actual local effective identity is available without a global cache" do
    assert {:ok, uid} = EffectiveUID.resolve()
    assert is_integer(uid) and uid >= 0
    assert EffectiveUID.resolve() == {:ok, uid}

    assert EffectiveUID.resolve({:unix, :linux}, fn -> {:error, :enoent} end) == {:ok, uid}
  end

  defp fixture_port(body) do
    python = System.find_executable("python3") || raise "identity boundary tests require Python"
    Port.open({:spawn_executable, python}, [:binary, :exit_status, args: ["-c", body]])
  end
end
