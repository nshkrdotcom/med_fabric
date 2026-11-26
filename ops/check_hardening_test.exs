# Run with plain Elixir: elixir ops/check_hardening_test.exs
ExUnit.start()

defmodule MedFabric.HardeningCheckTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  @moduletag :tmp_dir
  @script Path.expand("check_hardening.exs", __DIR__)
  @guides ~w(failure_matrix operations_and_telemetry security_and_clinical_boundary core_api_and_compatibility)

  setup %{tmp_dir: root} do
    for directory <- ["ops", "guides", "apps/exam/lib", "apps/exam/test"] do
      File.mkdir_p!(Path.join(root, directory))
    end

    File.cp!(@script, Path.join(root, "ops/check_hardening.exs"))
    File.write!(Path.join(root, ".gitignore"), "erl_crash.dump\n")
    File.write!(Path.join(root, "apps/exam/mix.exs"), "[]\n")

    for guide <- @guides do
      File.write!(Path.join(root, "guides/#{guide}.md"), "# Fixture\n")
    end

    %{root: root}
  end

  test "accepts existing cited files and suite directories", %{root: root} do
    File.write!(Path.join(root, "ops/fixture.exs"), ":ok\n")
    matrix(root, "`ops/fixture.exs`, `apps/exam/test/`, `guides/operations_and_telemetry.md`")
    assert capture_io(fn -> run(root) end) == "check_hardening ok\n"
  end

  test "rejects a missing test path instead of skipping the regex capture", %{root: root} do
    matrix(root, "`apps/exam/test/missing_test.exs`")

    assert_raise RuntimeError,
                 ~r/failure_matrix cites missing path: apps\/exam\/test\/missing_test.exs/,
                 fn -> run(root) end
  end

  test "rejects a missing cited guide", %{root: root} do
    matrix(root, "`guides/missing.md`")

    assert_raise RuntimeError, ~r/failure_matrix cites missing path: guides\/missing.md/, fn ->
      run(root)
    end
  end

  defp matrix(root, text), do: File.write!(Path.join(root, "guides/failure_matrix.md"), text)

  defp run(root), do: Code.eval_file(Path.join(root, "ops/check_hardening.exs"))
end
