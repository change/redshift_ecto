defmodule RedshiftEcto do
  @moduledoc """
  Adapter module for Redshift.

  It uses `postgrex` for communicating to the database and a connection pool,
  such as `poolboy`.

  This adapter is based on Ecto's builtin `Ecto.Adapters.Postgres` adapter. It
  delegates some functions to it but changes the implementation of most that
  are incompatible with Redshift. The differences are detailed in this
  documentation.

  We also recommend developers to consult the documentation of the
  [Postgres adapter](https://hexdocs.pm/ecto/Ecto.Adapters.Postgres.html).

  ## Notable differences

  * no array type
  * maps are stored as json in `varchar(max)` columns
  * the `:binary_id` and `:uuid` Ecto types are stored in `char(36)` and
    generated as text
  * no binary type and literal support
  * no aliases in `UPDATE` and `DELETE FROM` statements
  * no `RETURNING`
  * no support for `on_conflict` (except for the default `:raise`)
  * no support for `on_delete` and `on_update` on foreign key definitions
  * no support for `ALTER COLUMN`
  * no support for `CHECK` and `EXCLUDE` constraints
  * since Redshift doesn't enforce uniqueness and foreign key constraints the
    adapter can't report violations
  """

  # Inherit all behaviour from Ecto.Adapters.SQL
  use Ecto.Adapters.SQL, :postgrex

  alias Ecto.Adapters.Postgres

  # And provide a custom storage implementation
  @behaviour Ecto.Adapter.Storage
  @behaviour Ecto.Adapter.Structure

  defdelegate extensions, to: Postgres

  ## Custom Redshift types

  @doc false
  def autogenerate(:id), do: nil
  def autogenerate(:embed_id), do: Ecto.UUID.generate()
  def autogenerate(:binary_id), do: Ecto.UUID.generate()

  @doc false
  def loaders(:map, type), do: [&json_decode/1, type]
  def loaders({:map, _}, type), do: [&json_decode/1, type]

  def loaders({:embed, _} = type, _) do
    [&json_decode/1, &Ecto.Adapters.SQL.load_embed(type, &1)]
  end

  def loaders(:binary_id, _type), do: [&{:ok, &1}]
  def loaders(:uuid, Ecto.UUID), do: [&{:ok, &1}]
  def loaders(_, type), do: [type]

  defp json_decode(x) when is_binary(x) do
    {:ok, Ecto.Adapter.json_library().decode!(x)}
  end

  defp json_decode(x), do: {:ok, x}

  @doc false
  def dumpers(:map, type), do: [type, &json_encode/1]
  def dumpers({:map, _}, type), do: [type, &json_encode/1]

  def dumpers({:embed, _} = type, _) do
    [&Ecto.Adapters.SQL.dump_embed(type, &1), &json_encode/1]
  end

  def dumpers(:binary_id, _type), do: [&Ecto.UUID.cast/1]
  def dumpers(:uuid, Ecto.UUID), do: [&Ecto.UUID.cast/1]
  def dumpers(_, type), do: [type]

  defp json_encode(%{} = x) do
    {:ok, Ecto.Adapter.json_library().encode!(x)}
  end

  defp json_encode(x), do: {:ok, x}

  ## Storage API

  @doc false
  def storage_up(opts) do
    database =
      Keyword.fetch!(opts, :database) || raise ":database is nil in repository configuration"

    encoding = opts[:encoding] || "UTF8"
    opts = Keyword.put(opts, :database, "template1")

    command = ~s(CREATE DATABASE "#{database}" ENCODING '#{encoding}')

    case run_query(command, opts) do
      {:ok, _} ->
        :ok

      {:error, %{postgres: %{code: :duplicate_database}}} ->
        {:error, :already_up}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  @doc false
  def storage_down(opts) do
    database =
      Keyword.fetch!(opts, :database) || raise ":database is nil in repository configuration"

    command = "DROP DATABASE \"#{database}\""
    opts = Keyword.put(opts, :database, "template1")

    case run_query(command, opts) do
      {:ok, _} ->
        :ok

      {:error, %{postgres: %{code: :invalid_catalog_name}}} ->
        {:error, :already_down}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  @doc false
  def supports_ddl_transaction? do
    true
  end

  defdelegate structure_dump(default, config), to: Postgres
  defdelegate structure_load(default, config), to: Postgres

  ## Helpers

  defp run_query(sql, opts) do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    opts =
      opts
      |> Keyword.drop([:name, :log])
      |> Keyword.put(:pool, DBConnection.Connection)
      |> Keyword.put(:backoff_type, :stop)

    {:ok, pid} = Task.Supervisor.start_link()

    task =
      Task.Supervisor.async_nolink(pid, fn ->
        {:ok, conn} = Postgrex.start_link(opts)

        value = RedshiftEcto.Connection.execute(conn, sql, [], opts)
        GenServer.stop(conn)
        value
      end)

    timeout = Keyword.get(opts, :timeout, 15_000)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, error}} ->
        {:error, error}

      {:exit, {%{__struct__: struct} = error, _}}
      when struct in [Postgrex.Error, DBConnection.Error] ->
        {:error, error}

      {:exit, reason} ->
        {:error, RuntimeError.exception(Exception.format_exit(reason))}

      nil ->
        {:error, RuntimeError.exception("command timed out")}
    end
  end
end
