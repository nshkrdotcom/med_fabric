defmodule MedFabric.Preview.LogPrivacy do
  @moduledoc false
  @filter :mf_preview_privacy
  @dependencies ~w(Elixir.ExWebRTC Elixir.ExICE Elixir.ExSTUN Elixir.ExTURN Elixir.ExDTLS Elixir.ExLibSRTP Elixir.Postgrex Elixir.DBConnection Elixir.Phoenix Elixir.Bandit Elixir.WebSock Elixir.Req Elixir.Finch Elixir.Mint)
  @owners ~w(Elixir.MedFabric Elixir.MedEx)

  # Installed at the executable host, before opening listeners or admitting
  # media. A provider dependency never changes the embedding host's Logger.
  def install do
    filter = {&filter/2, []}

    case List.keyfind(:logger.get_primary_config().filters, @filter, 0) do
      {@filter, ^filter} -> :ok
      nil -> :logger.add_primary_filter(@filter, filter)
      _ -> {:error, :privacy_filter_conflict}
    end
  end

  def filter(%{meta: meta} = event, _) do
    cond do
      module_in?(origin(meta[:mfa]), @dependencies) ->
        sanitize(event, "mf_preview_dependency_event")

      otp?(meta) and sensitive_report?(event) ->
        sanitize(event, "mf_preview_otp_report")

      true ->
        :ignore
    end
  end

  defp otp?(meta), do: match?([:otp | _], meta[:domain])

  defp sensitive_report?(%{msg: {:report, report}, meta: meta}) do
    sensitive_process?(meta[:pid]) or report_owner?(report)
  end

  defp sensitive_report?(%{meta: meta}), do: sensitive_process?(meta[:pid])

  defp sensitive_process?(pid) when is_pid(pid) and node(pid) == node() do
    module_in?(origin(:proc_lib.translate_initial_call(pid)), @dependencies ++ @owners)
  end

  defp sensitive_process?(_), do: false

  defp report_owner?(report) when is_map(report) or is_list(report) do
    module_in?(origin(field(report, :initial_call)), @dependencies ++ @owners) or
      module_in?(origin(field(report, :mfargs)), @dependencies ++ @owners) or
      module_in?(field(report, :name), @owners) or
      proc_lib_owner?(field(report, :label), field(report, :report)) or
      application_owner?(field(report, :label), field(report, :application)) or
      child_owner?(field(report, :report)) or child_owner?(field(report, :offender))
  end

  defp report_owner?(_), do: false

  # proc_lib reports have a fixed [own_report, neighbour_reports] shape. The
  # originating process may already be dead when a handler replays the event.
  # Inspect only ownership fields, never arbitrary message/dictionary contents.
  defp proc_lib_owner?({:proc_lib, :crash}, [own_report, neighbours])
       when is_list(neighbours) do
    crash_owner?(own_report) or
      Enum.any?(neighbours, fn
        {:neighbour, report} -> crash_owner?(report)
        report -> crash_owner?(report)
      end)
  end

  defp proc_lib_owner?(_, _), do: false

  defp crash_owner?(report) do
    module_in?(origin(field(report, :initial_call)), @dependencies ++ @owners) or
      module_in?(field(report, :registered_name), @owners)
  end

  defp application_owner?({:application_controller, :exit}, app),
    do: app in [:mf_exam, :mf_preview, :mf_handheld]

  defp application_owner?(_, _), do: false

  defp child_owner?(report) when is_map(report) or is_list(report) do
    module_in?(origin(field(report, :mfargs)), @dependencies ++ @owners) or
      module_in?(field(report, :id), @owners) or
      module_in?(origin(field(field(report, :offender), :mfargs)), @dependencies ++ @owners)
  end

  defp child_owner?(_), do: false

  defp field(map, key) when is_map(map), do: Map.get(map, key)

  defp field(list, key) when is_list(list),
    do: if(Keyword.keyword?(list), do: Keyword.get(list, key))

  defp field(_, _), do: nil

  defp origin({module, _, _}) when is_atom(module), do: module
  defp origin(_), do: nil

  defp module_in?(module, prefixes) when is_atom(module) and not is_nil(module) do
    value = Atom.to_string(module)
    Enum.any?(prefixes, &(value == &1 or String.starts_with?(value, &1 <> ".")))
  end

  defp module_in?(_, _), do: false

  defp sanitize(event, code) do
    # Never carry arbitrary metadata, report callbacks, request IDs or exception
    # terms into downstream handlers. Preserve severity and safe origin only.
    meta = Map.take(event.meta, [:time, :pid, :gl])

    meta =
      case event.meta[:mfa] do
        {module, function, arity}
        when is_atom(module) and is_atom(function) and is_integer(arity) ->
          Map.put(meta, :mfa, {module, function, arity})

        _ ->
          meta
      end

    %{event | msg: {:string, code}, meta: meta}
  end
end
