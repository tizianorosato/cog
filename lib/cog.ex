defmodule Cog do
  require Logger
  use Application

  import Supervisor.Spec, warn: false

  def start(_type, _args) do
    sanity_check_vm()
    adapter_supervisor = get_adapter_supervisor!()
    children = build_children(Mix.env, System.get_env("NOCHAT"), adapter_supervisor)

    opts = [strategy: :one_for_one, name: Cog.Supervisor]
    started = Supervisor.start_link(children, opts)

    # Verify the latest schema migration after starting the database worker
    {sm_status, sm_message} = verify_schema_migration()
    log_message(sm_status, sm_message)
    if sm_status == :error do
      abort_cog()
    else
      started
    end
  end

  @doc "The name of the embedded command bundle."
  def embedded_bundle, do: "operable"

  @doc "The name of the site namespace."
  def site_namespace, do: "site"

  defp build_children(:dev, nochat, _) when nochat != nil do
    [worker(Cog.Repo, []),
     worker(Cog.TokenReaper, []),
     supervisor(Cog.Endpoint, [])]
  end
  defp build_children(_, _, adapter_supervisor) do
    [worker(Cog.Repo, []),
     worker(Cog.BusDriver, [], shutdown: 10000),
     worker(Cog.TokenReaper, []),
     worker(Cog.TemplateCache, []),
     worker(Carrier.CredentialManager, []),
     supervisor(Cog.Relay.RelaySup, []),
     supervisor(Cog.Command.CommandSup, []),
     supervisor(adapter_supervisor, []),
     supervisor(Cog.Endpoint, [])]
  end

  defp get_adapter_supervisor!() do
    adapter = Application.get_env(:cog, :adapter)
    Logger.info "Using #{adapter} chat adapter"

    case adapter_module(String.downcase(adapter)) do
      {:ok, module} ->
        supervisor = Module.concat(module, "Supervisor")

        case Code.ensure_loaded(supervisor) do
          {:module, module} ->
            module
          {:error, _} ->
            raise RuntimeError, "#{inspect(supervisor)} was not found. Please define a supervisor for the #{adapter} adapter"
        end
      {:error, msg} ->
        raise RuntimeError, "Please configure a chat adapter before starting cog. #{msg}"
    end
  end

  def adapter_module("slack"), do: {:ok, Cog.Adapters.Slack}
  def adapter_module("hipchat"), do: {:ok, Cog.Adapters.HipChat}
  def adapter_module("irc"), do: {:ok, Cog.Adapters.IRC}
  def adapter_module("null"), do: {:ok, Cog.Adapters.Null}
  def adapter_module("test"), do: {:ok, Cog.Adapters.Test}
  def adapter_module(bad_adapter) do
    {:error, "The adapter is set to '#{bad_adapter}', but I don't know what that is. Try 'slack' or 'hipchat' instead."}
  end

  defp sanity_check_vm() do
    {smp_status, smp_message} = verify_smp()
    log_message(smp_status, smp_message)

    {ds_status, ds_message} = verify_dirty_schedulers()
    log_message(ds_status, ds_message)

    if smp_status == :error or ds_status == :error, do: abort_cog()
  end

  defp log_message(:ok, message), do: Logger.info(message)
  defp log_message(:error, message), do: Logger.error(message)
  defp log_message(_status, message), do: Logger.warn(message)

  defp verify_smp() do
    if :erlang.system_info(:schedulers_online) < 2 do
      {:error, """
SMP support disabled.
SMP support can be enabled via one of the following:

  1. Add '--erl "-smp enable"' to the Elixir args in Cog's launch script.
  2. Add '-smp enable' to the $ERL_FLAGS environment variable.
"""}
    else
      {:ok, "SMP support enabled."}
    end
  end

  defp verify_dirty_schedulers() do
    try do
      :erlang.system_info(:dirty_cpu_schedulers)
      {:ok, "Dirty CPU schedulers enabled."}
    rescue
      ArgumentError ->
        {:error, """
Erlang VM is missing support for dirty CPU schedulers.
See http://erlang.org/doc/installation_guide/INSTALL.html for information on enabling dirty scheduler support.
"""}
    end
  end

  defp verify_schema_migration() do
    cond do
      migration_needed? and Mix.env == :dev ->
        {:dev, "The migration schema is not synchronized. Allowing to continue in the development environment."}
      migration_needed? ->
        {:error, "The migration schema is not up-to-date. Please perform a migration and restart Cog."}
      true ->
        {:ok, "Schema is at the current version"}
    end
  end

  defp migration_needed?() do
    [last_file_version, _] = Path.join([:code.priv_dir(:cog), "repo", "migrations"])
    |> File.ls!
    |> Enum.max
    |> String.split("_", parts: 2)

    last_db_version = Enum.max(Ecto.Migration.SchemaMigration.migrated_versions(Cog.Repo, "public"))

    if last_db_version != String.to_integer(last_file_version) do
      true
    else
      false
    end
  end

  defp abort_cog() do
    Logger.error("Application start aborted.")
    Logger.flush()
    :init.stop()
  end
end
