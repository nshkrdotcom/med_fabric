defmodule MedFabric.Exam.RootOwnershipTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias MedFabric.Exam.{DeviceRootLock, EffectiveUID}
  @uuid "00000000-0000-4000-8000-000000000002"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "mf-root-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "expected root refusal does not crash a non-trapping caller or expose its namespace", %{
    root: root
  } do
    sentinel = "synthetic-root-secret-e6df08f1"
    File.write!(Path.join(root, sentinel), sentinel)

    log =
      capture_log(fn ->
        assert {:error, :unmarked_artifact_namespace} =
                 DeviceRootLock.start_link(
                   name: __MODULE__.Owner,
                   root: root,
                   deployment_uuid: @uuid
                 )
      end)

    assert Process.alive?(self())
    assert Process.whereis(__MODULE__.Owner) == nil
    refute log =~ sentinel
    refute log =~ "crasher"
  end

  test "ownership is freshly denied after chmod, symlink or same-UID root replacement", %{
    root: root
  } do
    {:ok, owner} =
      DeviceRootLock.start_link(name: __MODULE__.Owner, root: root, deployment_uuid: @uuid)

    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
    assert {:ok, %{token: token}} = GenServer.call(owner, {:med_ex_root_ownership, root})
    assert is_reference(token)

    File.chmod!(root, 0o777)
    assert {:error, :root_ownership_lost} = GenServer.call(owner, {:med_ex_root_ownership, root})
    File.chmod!(root, 0o700)

    moved = root <> "-moved"
    File.rename!(root, moved)
    on_exit(fn -> File.rm_rf!(moved) end)
    File.ln_s!(moved, root)
    assert {:error, :untrusted_artifact_root} = DeviceRootLock.trusted_path(root)
    assert {:error, :root_ownership_lost} = GenServer.call(owner, {:med_ex_root_ownership, root})
    File.rm!(root)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    assert :ok = DeviceRootLock.trusted_path(root)
    assert {:error, :root_ownership_lost} = GenServer.call(owner, {:med_ex_root_ownership, root})
    GenServer.stop(owner)
  end

  test "explicit release permits a terminal reply until a successor claims the gate", %{
    root: root
  } do
    {:ok, owner} =
      DeviceRootLock.start_link(name: __MODULE__.Owner, root: root, deployment_uuid: @uuid)

    key = {"acquisition", "audio"}
    assert :ok = DeviceRootLock.gate(owner, key)
    assert :ok = DeviceRootLock.bind_connection(owner, key, "old", self())
    assert DeviceRootLock.current_connection?(owner, key, "old")
    assert :ok = DeviceRootLock.release(owner, key)
    assert DeviceRootLock.current_connection?(owner, key, "old")

    assert :ok = DeviceRootLock.gate(owner, key)
    assert :ok = DeviceRootLock.release(owner, key)
    refute DeviceRootLock.current_connection?(owner, key, "old")
    GenServer.stop(owner)
  end

  test "wrong types and writable nonsticky ancestors fail closed", %{root: root} do
    file = Path.join(root, "file")
    File.write!(file, "")
    assert {:error, :untrusted_artifact_root} = DeviceRootLock.trusted_path(file)
    nested = Path.join(root, "nested")
    File.mkdir!(nested)
    File.chmod!(nested, 0o700)
    File.chmod!(root, 0o777)
    assert {:error, :untrusted_artifact_root} = DeviceRootLock.trusted_path(nested)
  end

  test "a root owned by a different effective UID is denied", %{root: root} do
    {:ok, uid} = EffectiveUID.resolve()

    if uid == 0 do
      File.chown!(root, 1)
      assert {:error, :untrusted_artifact_root} = DeviceRootLock.trusted_path(root)
      File.chown!(root, uid)
    else
      assert {:error, :untrusted_artifact_root} = DeviceRootLock.trusted_path("/")
    end
  end
end
