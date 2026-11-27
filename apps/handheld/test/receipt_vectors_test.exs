defmodule MedExHandheld.ReceiptVectorsTest do
  use ExUnit.Case, async: true
  alias MedEx.Receipt
  @sha "00e4b87285b26e995f5f0e3bff01c3cce5a8f3c4701e41d9f3981b73a197901b"

  test "Handheld executes the identical canonical Receipt corpus used by the SDK and browser" do
    path = System.get_env("MEDEX_RECEIPT_VECTORS") || Path.expand("../../../../med_ex/core/med_core/test/fixtures/receipt_vectors_v2.json", __DIR__)
    bytes = File.read!(path)
    assert MedEx.Serialization.sha256(bytes) == @sha
    %{"schema" => "medex.receipt_vectors.v2", "api_revision" => 2, "cases" => cases} = JSON.decode!(bytes)
    assert length(cases) == 51
    assert Enum.uniq(Enum.map(cases, & &1["id"])) |> length() == length(cases)
    for vector <- cases do
      actual = run(vector)
      expected = vector["expected"]
      assert actual == expected, "#{vector["id"]}: #{inspect(actual)} != #{expected}"
    end
  end

  defp run(%{"operation" => "parse", "proposed" => wire}), do: classify(Receipt.parse(wire))
  defp run(%{"operation" => "observe", "previous" => old, "proposed" => new}), do: classify(Receipt.observe(old, new))
  defp run(%{"operation" => "commit", "previous" => old, "proposed" => new, "planned_cursor" => planned}) do
    classify(Receipt.committed_successor(old, new, %{next_sequence: String.to_integer(planned["next_sequence"]), next_sample: String.to_integer(planned["next_sample"])}))
  end
  defp run(%{"operation" => "exact", "previous" => old, "proposed" => new}), do: to_string(Receipt.exact_prefix?(old, new))
  defp run(%{"operation" => "handoff", "previous" => old, "proposed" => new} = vector) do
    binding = if is_map(vector["binding"]), do: vector["binding"], else: %{}
    authority = if binding["authority"] == "authenticated_host", do: :authenticated_host, else: :untrusted
    classify(Receipt.handoff(old, new, %{previous: binding["previous"], successor: binding["successor"], imported: binding["imported"],
      authority: authority, authenticated: binding["authenticated"] == true, quiescent: binding["quiescent"] == true}))
  end
  defp classify(:ok), do: "ok"
  defp classify({:ok, _}), do: "ok"
  defp classify({:error, reason}), do: to_string(reason)
end
