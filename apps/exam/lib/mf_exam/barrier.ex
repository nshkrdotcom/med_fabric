defmodule MedFabric.Exam.Barrier do
  @moduledoc false
  def hit(name, stream \\ "all") do
    if dir = Application.get_env(:mf_exam, :barriers) do
      key = Path.join(dir, name <> "." <> stream)

      if File.exists?(key <> ".armed") and File.rename(key <> ".armed", key <> ".reached") == :ok do
        deadline = System.monotonic_time(:millisecond) + 30_000
        wait(key, deadline)
      end
    end

    :ok
  end

  defp wait(key, deadline) do
    if File.exists?(key <> ".reached") do
      if System.monotonic_time(:millisecond) > deadline, do: raise("barrier expired")
      Process.sleep(25)
      wait(key, deadline)
    end
  end
end
