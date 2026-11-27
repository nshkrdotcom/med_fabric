defmodule MedFabric.Exam.EffectiveUID do
  @moduledoc false
  @timeout 1_000
  @output_limit 32

  # Identity is resolved afresh at each ownership boundary, never cached in
  # application environment, a process dictionary or a VM-global registry.
  def resolve do
    resolve(:os.type(), fn -> File.read("/proc/self/status") end)
  end

  @doc false
  def resolve(platform, read_status), do: resolve(platform, read_status, &command/0)

  @doc false
  def resolve({:unix, :linux}, read_status, fallback) do
    case read_status.() do
      {:ok, status} -> parse_status(status)
      {:error, _} -> fallback.()
    end
  end

  def resolve({:unix, _}, _read_status, fallback), do: fallback.()
  def resolve(_, _, _), do: {:error, :unsupported_identity_platform}

  @doc false
  def parse_status(status) when is_binary(status) and byte_size(status) <= 65_536 do
    with [line] <- status |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "Uid:")),
         [_, real, effective, saved, filesystem] <-
           Regex.run(~r/\AUid:[\t ]+([0-9]+)[\t ]+([0-9]+)[\t ]+([0-9]+)[\t ]+([0-9]+)[\t ]*\z/, line),
         {:ok, _} <- uid(real),
         {:ok, value} <- uid(effective),
         {:ok, _} <- uid(saved),
         {:ok, _} <- uid(filesystem) do
      {:ok, value}
    else
      _ -> {:error, :invalid_effective_uid}
    end
  end

  def parse_status(_), do: {:error, :invalid_effective_uid}

  @doc false
  def parse_output(output) when is_binary(output) and byte_size(output) <= @output_limit,
    do: output |> String.replace_suffix("\n", "") |> uid()

  def parse_output(_), do: {:error, :invalid_effective_uid}

  defp uid(value) do
    with true <- byte_size(value) in 1..10,
         {uid, ""} <- Integer.parse(value),
         true <- uid in 0..0xFFFFFFFF and Integer.to_string(uid) == value do
      {:ok, uid}
    else
      _ -> {:error, :invalid_effective_uid}
    end
  end

  defp command do
    case Enum.find(["/usr/bin/id", "/bin/id"], &trusted_executable?/1) do
      nil ->
        {:error, :identity_command_unavailable}

      path ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["-u"]
          ])

        read_port(port, @timeout)
    end
  rescue
    _ in [ArgumentError, ErlangError] -> {:error, :identity_command_unavailable}
  end

  defp trusted_executable?(path) do
    with {:ok, %{type: :regular, uid: 0, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o6022) == 0 and Bitwise.band(mode, 0o111) != 0 do
      trusted_directory?(Path.dirname(path))
    else
      _ -> false
    end
  end

  defp trusted_directory?(path) do
    with {:ok, %{type: :directory, uid: 0, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o022) == 0 do
      path == "/" or trusted_directory?(Path.dirname(path))
    else
      _ -> false
    end
  end

  @doc false
  def read_port(port, timeout) when is_port(port) and timeout in 1..@timeout do
    try do
      collect(port, System.monotonic_time(:millisecond) + timeout, "")
    after
      close_port(port)
    end
  end

  defp collect(port, deadline, output) do
    receive do
      {^port, {:data, bytes}} when byte_size(output) + byte_size(bytes) <= @output_limit ->
        collect(port, deadline, output <> bytes)

      {^port, {:data, _}} ->
        {:error, :invalid_effective_uid}

      {^port, {:exit_status, 0}} ->
        parse_output(output)

      {^port, {:exit_status, _}} ->
        {:error, :identity_command_failed}

      {:EXIT, ^port, _} ->
        {:error, :identity_command_failed}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, :identity_timeout}
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
