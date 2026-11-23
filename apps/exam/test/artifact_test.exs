defmodule MedFabric.Exam.ArtifactTest do
  use ExUnit.Case, async: true

  alias MedFabric.Exam.Artifact
  import Plug.Conn

  @moduletag :tmp_dir
  @id "a-valid-recording-id-123"

  setup %{tmp_dir: dir} do
    pcm = <<10, 20, 30, 40>>

    wav =
      <<"RIFF", 40::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
        48_000::little-32, 96_000::little-32, 2::little-16, 16::little-16, "data", 4::little-32,
        pcm::binary>>

    digest = hex(wav)
    key = @id <> "/" <> digest <> ".wav"
    :ok = Artifact.create_directory(dir, @id)
    path = Path.join(dir, key)
    File.write!(path, wav)

    evidence = %{
      "artifact_key" => key,
      "file_sha256" => digest,
      "pcm_sha256" => hex(pcm),
      "sample_rate_hz" => 48_000,
      "sample_count" => 2
    }

    %{wav: wav, evidence: evidence, path: path}
  end

  test "streams the verified inode even when its path is replaced before sending", c do
    conn =
      Plug.Test.conn(:get, "/")
      |> register_before_send(fn conn ->
        File.rename!(c.path, c.path <> ".old")
        File.write!(c.path, "replacement")
        conn
      end)

    sent = Artifact.serve(conn, c.tmp_dir, @id, c.evidence)
    assert sent.status == 200
    assert sent.resp_body == c.wav
    assert {:error, _} = Artifact.verify(c.tmp_dir, @id, c.evidence)
  end

  test "ranges include both offsets, clamp at EOF, and reject unsatisfiable positions", c do
    for {range, status, body, content_range} <- [
          {"bytes=44-45", 206, <<10, 20>>, "bytes 44-45/48"},
          {"bytes=46-", 206, <<30, 40>>, "bytes 46-47/48"},
          {"bytes=47-999", 206, <<40>>, "bytes 47-47/48"},
          {"bytes=-1", 206, <<40>>, "bytes 47-47/48"},
          {"bytes=48-", 416, "", "bytes */48"}
        ] do
      conn = Plug.Test.conn(:get, "/") |> put_req_header("range", range)
      sent = Artifact.serve(conn, c.tmp_dir, @id, c.evidence)
      assert sent.status == status
      assert sent.resp_body == body
      assert get_resp_header(sent, "content-range") == [content_range]
    end
  end

  test "only the bound attempt may use the verified file", c do
    assert {:error, _} = Artifact.verify(c.tmp_dir, "another-id", c.evidence)
    basename = Path.basename(c.path)
    File.rename!(c.path, Path.join(c.tmp_dir, basename))

    assert {:error, :invalid_recording} =
             Artifact.verify(c.tmp_dir, @id, %{c.evidence | "artifact_key" => basename})
  end

  test "a matching filename hash cannot make a noncanonical WAV recoverable", c do
    File.rm!(c.path)
    bad_wav = String.replace(c.wav, "WAVE", "FAKE")
    File.write!(Path.join([c.tmp_dir, @id, hex(bad_wav) <> ".wav"]), bad_wav)
    assert {:error, :invalid_recording} = Artifact.finalized(c.tmp_dir, @id)
  end

  defp hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
