defmodule MedFabric.Exam.AcquisitionRecovery do
  @moduledoc "Operator recovery of an already blocked namespace using actual quiescent journals, installed manifests and an authoritative later DB/WAL inventory."
  alias MedFabric.Exam.{AcquisitionIngress, AcquisitionManifest, DeviceRootLock}
  alias MedFabric.Store.{AcquisitionSessions, Recovery}
  alias MedEx.{Receipt, Serialization, CanonicalJSON}
  alias MedEx.Storage.File, as: Storage

  @doc "Capture a quiesced authority inventory only after every artifact agrees with its current durable SQL projection."
  def inventory(context) do
    with_catalog(context, fn proof ->
      with {:ok, inventory} <- Recovery.inventory(context.db),
           {:ok, _} <- Recovery.inspect_inventory(inventory.bytes, inventory.digest),
           :ok <- validate_projection(context, proof) do
        {:ok, inventory}
      end
    end)
  end

  @doc "Verify local effects under the OS root and stream gates, then resume only an exact authoritative catalog. Missing later DB facts remain blocked."
  def reconcile(context, bytes, digest) do
    with {:ok, _} <- Recovery.inspect_inventory(bytes, digest) do
      with_catalog(context, fn proof -> Recovery.reconcile(context.db, bytes, digest, proof) end)
    end
  end

  defp with_catalog(context, fun) do
    with {:ok, catalog} <- Recovery.artifact_catalog(context.db),
         {:ok, %{root: root, token: token}} <-
           GenServer.call(
             context.root_owner,
             {:med_ex_root_ownership, context.artifact_dir},
             1_000
           ),
         :ok <- namespace(context, catalog),
         {:ok, held} <- gates(context, catalog) do
      result =
        try do
          with {:ok, prefixes} <- prefixes(context, catalog.attempts),
               {:ok, manifests} <- manifests(context, catalog.manifests) do
            proof = %{
              root: root,
              root_owner: context.root_owner,
              root_token: token,
              prefixes: prefixes,
              manifests: manifests
            }

            fun.(proof)
          end
        catch
          :exit, _ -> {:error, :recovery_effect_unknown}
        end

      Enum.each(held, fn key ->
        if match?({:ok, _}, result),
          do: DeviceRootLock.release(context.root_owner, key),
          else: DeviceRootLock.poison(context.root_owner, key)
      end)

      result
    end
  catch
    :exit, _ -> {:error, :recovery_effect_unknown}
  end

  defp gates(context, catalog) do
    keys =
      for acquisition <- catalog.acquisitions,
          name <- Map.keys(acquisition.descriptors),
          do: {acquisition.id, name}

    Enum.reduce_while(Enum.sort(keys), {:ok, []}, fn {id, name} = key, {:ok, held} ->
      case AcquisitionIngress.acquire_gate(context, id, name) do
        :ok ->
          {:cont, {:ok, [key | held]}}

        error ->
          Enum.each(held, &DeviceRootLock.release(context.root_owner, &1))
          {:halt, error}
      end
    end)
  end

  defp prefixes(context, attempts) do
    Enum.reduce_while(attempts, {:ok, []}, fn attempt, {:ok, found} ->
      dir =
        AcquisitionManifest.attempt_dir(
          context,
          attempt.acquisition,
          attempt.stream,
          attempt.fence
        )

      if is_nil(attempt.receipt) and File.lstat(dir) == {:error, :enoent} do
        {:cont, {:ok, found}}
      else
        with {:ok, spec} <- Serialization.stream_spec(attempt.descriptor),
             {:ok, known} <- Receipt.parse(attempt.receipt),
             {:ok, prefix} <-
               Storage.recover(dir,
                 stream: spec,
                 fence: attempt.fence,
                 known_receipt: known,
                 root_owner: context.root_owner
               ),
             true <-
               Receipt.exact_prefix?(known, prefix.receipt) and
                 prefix.index_digest == attempt.index_digest do
          {:cont, {:ok, [prefix | found]}}
        else
          _ -> {:halt, {:error, :unaccounted_artifact_prefix}}
        end
      end
    end)
  end

  defp manifests(context, entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, found} ->
      path = Path.join(AcquisitionManifest.root(context, entry.acquisition), "manifest.mej1")

      with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
           true <- size in 1..16_777_216,
           {:ok, bytes} <- File.read(path),
           true <-
             byte_size(bytes) == size and AcquisitionSessions.hash(bytes) == entry.digest and
               CanonicalJSON.encode(entry.body) == bytes do
        {:cont, {:ok, Map.put(found, entry.acquisition, bytes)}}
      else
        _ -> {:halt, {:error, :unaccounted_manifest}}
      end
    end)
  end

  # This scan catches journals/manifest directories that exist after the restored
  # SQL cut point. A coherent older DB cannot make those effects disappear.
  defp namespace(context, catalog) do
    base = Path.join(context.artifact_dir, "acquisitions-v2")
    known = Map.new(catalog.acquisitions, &{AcquisitionSessions.hash(&1.id), &1})

    with {:ok, entries} <- children(base) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        case known[entry] do
          nil ->
            {:halt, {:error, :unaccounted_acquisition_artifacts}}

          acquisition ->
            path = Path.join(base, entry)

            with :ok <- DeviceRootLock.trusted_path(path), {:ok, files} <- children(path) do
              result =
                Enum.reduce_while(files, :ok, fn file, :ok ->
                  cond do
                    file == "manifest.mej1" and
                        Enum.any?(catalog.manifests, &(&1.acquisition == acquisition.id)) ->
                      {:cont, :ok}

                    Map.has_key?(acquisition.descriptors, file) ->
                      stream_dir = Path.join(path, file)

                      allowed =
                        for a <- catalog.attempts,
                            a.acquisition == acquisition.id and a.stream == file,
                            do: a.fence

                      with :ok <- DeviceRootLock.trusted_path(stream_dir),
                           {:ok, fences} <- children(stream_dir),
                           true <- Enum.all?(fences, &(&1 in allowed)) do
                        {:cont, :ok}
                      else
                        _ -> {:halt, {:error, :unaccounted_stream_artifacts}}
                      end

                    true ->
                      {:halt, {:error, :unaccounted_acquisition_artifacts}}
                  end
                end)

              if result == :ok, do: {:cont, :ok}, else: {:halt, result}
            else
              _ -> {:halt, {:error, :untrusted_artifact_inventory}}
            end
        end
      end)
    end
  end

  defp children(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} when length(names) <= 100_000 -> {:ok, Enum.sort(names)}
          _ -> {:error, :artifact_inventory_capacity}
        end

      _ ->
        {:error, :untrusted_artifact_inventory}
    end
  end

  defp validate_projection(context, proof) do
    with {:ok, catalog} <- Recovery.artifact_catalog(context.db) do
      expected = Enum.sort_by(Enum.reject(catalog.attempts, &is_nil(&1.receipt)), & &1.fence)
      found = Enum.sort_by(proof.prefixes, & &1.fence)

      if length(expected) == length(found) and
           Enum.all?(Enum.zip(expected, found), fn {a, p} ->
             a.fence == p.fence and Receipt.exact_prefix?(a.receipt, p.receipt) and
               a.index_digest == p.index_digest
           end), do: :ok, else: {:error, :artifact_catalog_changed}
    end
  end
end
