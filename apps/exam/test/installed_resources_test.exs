defmodule MedFabric.Exam.InstalledResourcesTest do
  use ExUnit.Case, async: true
  @tag :tmp_dir
  test "installed resource bytes are bound to this compiled package revision before listener startup",
       %{tmp_dir: dir} do
    source = Application.app_dir(:mf_exam, "priv/static")

    for name <- ~w(exam.js acquisition.js acquisition_worklet.js),
        do: File.cp!(Path.join(source, name), Path.join(dir, name))

    assert :ok = MedFabric.Exam.Application.resources(dir)
    file = Path.join(dir, "acquisition.js")
    <<first, tail::binary>> = File.read!(file)
    File.write!(file, <<Bitwise.bxor(first, 1), tail::binary>>)
    assert {:error, :installed_assets_mismatch} = MedFabric.Exam.Application.resources(dir)
    File.cp!(Path.join(source, "acquisition.js"), file)
    File.rm!(Path.join(dir, "acquisition_worklet.js"))
    assert {:error, :installed_assets_mismatch} = MedFabric.Exam.Application.resources(dir)
  end
end
