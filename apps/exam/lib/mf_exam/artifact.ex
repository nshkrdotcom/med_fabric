defmodule MedFabric.Exam.Artifact do
  @moduledoc "Verifies and serves the canonical, write-once PCM WAV on the exam volume."
  import Plug.Conn

  @chunk 65_536
  @max_pcm_bytes 48_000 * 2 * 60 * 30
  @filename ~r/\A([0-9a-f]{64})\.wav\z/
  @attempt ~r/\A[A-Za-z0-9_-]{24}\z/

  def create_directory(root, id) do
    with :ok <- File.mkdir_p(root),
         :ok <- File.mkdir(Path.join(root, id)) do
      sync_directory(root)
    end
  end

  defp sync_directory(path) do
    with {:ok, fd} <- :file.open(path, [:read, :raw, :directory]) do
      try do
        :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end

  def remove_partials(root, id) do
    with true <- Regex.match?(@attempt, id),
         dir = Path.join(root, id),
         {:ok, names} <- File.ls(dir) do
      names
      |> Enum.filter(&Regex.match?(~r/\A\.capture-[A-Za-z0-9_-]{24}\.part\z/, &1))
      |> Enum.reduce_while(:ok, fn name, :ok ->
        case File.rm(Path.join(dir, name)) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      false -> {:error, :invalid_recording}
      error -> error
    end
  end

  def finalized(root, id) do
    with true <- Regex.match?(@attempt, id),
         dir = Path.join(root, id),
         {:ok, names} <- File.ls(dir) do
      case Enum.filter(names, &String.ends_with?(&1, ".wav")) do
        [] ->
          {:error, :unfinished}

        [name] ->
          with {:ok, artifact} <- inspect_file(dir, name, id, fn _, data -> {:ok, data} end),
               :ok <- sync_directory(dir) do
            {:ok, artifact}
          end

        _ ->
          {:error, :invalid_recording}
      end
    else
      false -> {:error, :invalid_recording}
      error -> error
    end
  end

  def verify(root, id, evidence), do: with_verified(root, id, evidence, fn _, _ -> :ok end)

  def serve(conn, root, id, evidence) do
    case with_verified(root, id, evidence, fn fd, size -> send_audio(conn, fd, size, evidence) end) do
      %Plug.Conn{} = sent -> sent
      {:error, _} -> send_resp(conn, 404, "Recording unavailable")
    end
  end

  defp with_verified(root, id, %{"file_sha256" => digest, "artifact_key" => key} = evidence, fun)
       when is_binary(digest) and is_binary(key) and is_binary(id) do
    name = digest <> ".wav"

    if Regex.match?(@attempt, id) and key == id <> "/" <> name do
      inspect_file(Path.join(root, id), name, id, fn fd, artifact ->
        if evidence["pcm_sha256"] == artifact.pcm_sha256 and
             evidence["sample_count"] == artifact.sample_count and
             evidence["sample_rate_hz"] == artifact.sample_rate_hz do
          fun.(fd, 44 + 2 * artifact.sample_count)
        else
          {:error, :recording_changed}
        end
      end)
    else
      {:error, :invalid_recording}
    end
  end

  defp with_verified(_, _, _, _), do: {:error, :invalid_recording}

  defp inspect_file(dir, name, id, fun) do
    with [_, digest] <- Regex.run(@filename, name),
         path = Path.join(dir, name),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, fd} <- :file.open(path, [:raw, :binary, :read]) do
      try do
        with {:ok, pcm_size, header} <- read_header(fd),
             file_hash = :crypto.hash_update(:crypto.hash_init(:sha256), header),
             {:ok, ^digest, pcm_hash} <-
               hashes(fd, pcm_size, file_hash, :crypto.hash_init(:sha256)) do
          count = div(pcm_size, 2)

          fun.(fd, %MedEx.Evidence{
            acquisition_id: id,
            artifact_key: name,
            file_sha256: digest,
            pcm_sha256: pcm_hash,
            sample_count: count,
            end_sample: count
          })
        else
          {:error, _} = error -> error
          _ -> {:error, :invalid_recording}
        end
      after
        :file.close(fd)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_recording}
    end
  end

  defp read_header(fd) do
    with {:ok, size} <- :file.position(fd, :eof),
         {:ok, 0} <- :file.position(fd, 0),
         {:ok, header} <- :file.read(fd, 44),
         <<"RIFF", riff::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
           48_000::little-32, 96_000::little-32, 2::little-16, 16::little-16, "data",
           bytes::little-32>> <- header,
         true <-
           bytes in 2..@max_pcm_bytes and rem(bytes, 2) == 0 and
             riff == bytes + 36 and size == bytes + 44 do
      {:ok, bytes, header}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_recording}
    end
  end

  defp hashes(_fd, 0, wav, pcm), do: {:ok, digest(wav), digest(pcm)}

  defp hashes(fd, remaining, wav, pcm) do
    case :file.read(fd, min(remaining, @chunk)) do
      {:ok, bytes} when byte_size(bytes) > 0 ->
        hashes(
          fd,
          remaining - byte_size(bytes),
          :crypto.hash_update(wav, bytes),
          :crypto.hash_update(pcm, bytes)
        )

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_recording}
    end
  end

  defp digest(hash), do: hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

  defp send_audio(conn, fd, size, evidence) do
    etag = "\"" <> evidence["file_sha256"] <> "\""

    conn =
      conn
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_content_type("audio/wav", nil)

    range =
      if get_req_header(conn, "if-range") in [[], [etag]],
        do: get_req_header(conn, "range"),
        else: []

    case byte_range(range, size) do
      {:ok, status, start, finish} ->
        conn =
          if status == 206 do
            put_resp_header(conn, "content-range", "bytes #{start}-#{finish}/#{size}")
          else
            conn
          end

        length = finish - start + 1

        conn
        |> put_resp_header("content-length", Integer.to_string(length))
        |> send_chunked(status)
        |> stream(fd, start, length)

      :unsatisfiable ->
        conn |> put_resp_header("content-range", "bytes */#{size}") |> send_resp(416, "")
    end
  end

  defp byte_range([], size), do: {:ok, 200, 0, size - 1}

  defp byte_range([range], size) do
    case Regex.run(~r/\Abytes=([0-9]*)-([0-9]*)\z/, range, capture: :all_but_first) do
      ["", ""] ->
        :unsatisfiable

      ["", suffix] ->
        case String.to_integer(suffix) do
          0 -> :unsatisfiable
          length -> {:ok, 206, max(size - length, 0), size - 1}
        end

      [first, last] ->
        start = String.to_integer(first)
        finish = if last == "", do: size - 1, else: min(String.to_integer(last), size - 1)
        if start <= finish, do: {:ok, 206, start, finish}, else: :unsatisfiable

      _ ->
        :unsatisfiable
    end
  end

  defp byte_range(_, _), do: :unsatisfiable

  defp stream(conn, _fd, _offset, 0), do: conn

  defp stream(conn, fd, offset, remaining) do
    # Keep this descriptor through the final chunk, including across pathname replacement.
    {:ok, bytes} = :file.pread(fd, offset, min(@chunk, remaining))

    case chunk(conn, bytes) do
      {:ok, conn} -> stream(conn, fd, offset + byte_size(bytes), remaining - byte_size(bytes))
      {:error, _} -> conn
    end
  end
end
