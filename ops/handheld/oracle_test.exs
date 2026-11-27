Code.require_file("oracle.exs", __DIR__)
ExUnit.start()

defmodule MedFabric.Acceptance.OracleTest do
  use ExUnit.Case, async: true
  alias MedFabric.Acceptance.Oracle

  test "independent known-answer sample hashes cover s16, gap, s24 and gain" do
    assert Oracle.sha(Oracle.samples(0, 8, 1, 2, 37, 1, [], 1)) ==
             "05ca032bf26c0d2090512e815855f44cf4cd852eff7da0dc659e39f077631200"

    assert Oracle.sha(Oracle.samples(0, 8, 2, 3, 37, 2, [{2, 4}], 1)) ==
             "cd95a0fe5df589de96aa5f1ac2f8b874ed4e9019705dd234868f3c07c44b6ade"

    assert Oracle.sha(Oracle.samples(0, 8, 1, 2, 37, 1, [], 2)) ==
             "6aa9b5e55d36b819ba9cda32306d4ea1fd4a3996a174d73967e44f53c596ae89"
  end

  test "spool cutoff rejects altered durable bytes" do
    root = Path.join(System.tmp_dir!(), "mf-oracle-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(root, "source.json"),
      JSON.encode!(%{"done" => false, "sequence" => 7, "sample" => 100})
    )

    frame =
      <<"MEX1", 1, 0, 48::16, 1::32, 0::32, 0::32, 7::64, 100::64, 20::32, 40::32, 0::32, 0::320>>

    path = Path.join(root, "7-100.rec")
    File.write!(path, :crypto.hash(:sha256, frame) <> frame)
    assert Oracle.restart_cutoff!(root) == 120

    File.write!(
      Path.join(root, "ack.json"),
      JSON.encode!(%{"receipt" => %{"durable_sequence" => "8", "durable_sample" => "120"}})
    )

    File.rm!(path)
    assert Oracle.restart_cutoff!(root) == 120
    File.rm!(Path.join(root, "ack.json"))
    File.write!(path, <<0::256>> <> frame)

    assert_raise RuntimeError, ~r/Corrupt independent spool/, fn ->
      Oracle.restart_cutoff!(root)
    end
  end

  test "retained gap advances the independently verified source prefix" do
    root = Path.join(System.tmp_dir!(), "mf-oracle-gap-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(root, "source.json"),
      JSON.encode!(%{"done" => false, "sequence" => 7, "sample" => 100})
    )

    gap = %{
      "id" => "lost-source",
      "first" => "100",
      "end" => "160",
      "first_sequence" => "7",
      "next_sequence" => "10",
      "irreversible" => true,
      "cause" => "source_overflow"
    }

    bytes = JSON.encode!(gap)
    path = Path.join(root, "7-100.rec")
    File.write!(path, :crypto.hash(:sha256, bytes) <> bytes)
    assert Oracle.restart_cutoff!(root) == 160

    for changed <- [
          Map.put(gap, "first", "0100"),
          Map.put(gap, "type", "gap"),
          Map.put(gap, "irreversible", false)
        ] do
      bytes = JSON.encode!(changed)
      File.write!(path, :crypto.hash(:sha256, bytes) <> bytes)

      assert_raise RuntimeError, ~r/Invalid independent source gap/, fn ->
        Oracle.restart_cutoff!(root)
      end
    end
  end
end
