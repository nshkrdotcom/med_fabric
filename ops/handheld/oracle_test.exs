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
    File.write!(Path.join(root, "source.json"), JSON.encode!(%{"done" => false, "sequence" => 7, "sample" => 100}))
    frame = <<"MEX1", 0::128, 7::64, 100::64, 20::32, 0::16>>
    path = Path.join(root, "7.rec")
    File.write!(path, :crypto.hash(:sha256, frame) <> frame)
    assert Oracle.restart_cutoff!(root) == 120
    File.write!(path, <<0::256>> <> frame)
    assert_raise RuntimeError, ~r/Corrupt independent spool/, fn -> Oracle.restart_cutoff!(root) end
  end
end
