defmodule Defdo.DevIdp.Store do
  @moduledoc """
  Authorization codes, access tokens and dev sessions, in memory.

  A GenServer owns three ETS tables. Reads and the single-use take happen in
  the caller: `:ets.take/2` is atomic, so a code can be exchanged exactly once
  even when two requests race.

  Codes live 60 seconds, tokens 3600 seconds. Nothing is written to disk and
  nothing here is ever logged.
  """

  use GenServer

  @codes :defdo_dev_idp_codes
  @tokens :defdo_dev_idp_tokens
  @sessions :defdo_dev_idp_sessions

  @code_ttl 60
  @token_ttl 3600

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Seconds a code lives."
  @spec code_ttl() :: pos_integer()
  def code_ttl, do: @code_ttl

  @doc "Seconds a token lives."
  @spec token_ttl() :: pos_integer()
  def token_ttl, do: @token_ttl

  @doc "A fresh opaque value: 32 random bytes, URL-safe."
  @spec random() :: String.t()
  def random, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @spec now() :: integer()
  def now, do: System.system_time(:second)

  @spec put_code(String.t(), map()) :: :ok
  def put_code(code, %{expires_at: _} = data) when is_binary(code) do
    true = :ets.insert(@codes, {code, data})
    :ok
  end

  @doc "Single use: the code is deleted on read. An expired code is `:error`."
  @spec take_code(String.t(), integer()) :: {:ok, map()} | :error
  def take_code(code, now \\ now())

  def take_code(code, now) when is_binary(code) do
    case :ets.take(@codes, code) do
      [{^code, %{expires_at: expires_at} = data}] when expires_at > now -> {:ok, data}
      _missing_or_expired -> :error
    end
  end

  def take_code(_code, _now), do: :error

  @spec put_token(String.t(), map()) :: :ok
  def put_token(token, %{expires_at: _} = data) when is_binary(token) do
    true = :ets.insert(@tokens, {token, data})
    :ok
  end

  @doc "An expired token is `:error` and is deleted."
  @spec get_token(String.t(), integer()) :: {:ok, map()} | :error
  def get_token(token, now \\ now())

  def get_token(token, now) when is_binary(token) do
    case :ets.lookup(@tokens, token) do
      [{^token, %{expires_at: expires_at} = data}] when expires_at > now ->
        {:ok, data}

      [{^token, _expired}] ->
        :ets.delete(@tokens, token)
        :error

      [] ->
        :error
    end
  end

  def get_token(_token, _now), do: :error

  @spec put_session(String.t(), atom()) :: :ok
  def put_session(sid, profile_key) when is_binary(sid) and is_atom(profile_key) do
    true = :ets.insert(@sessions, {sid, profile_key})
    :ok
  end

  @spec get_session(String.t() | nil) :: {:ok, atom()} | :error
  def get_session(sid) when is_binary(sid) do
    case :ets.lookup(@sessions, sid) do
      [{^sid, profile_key}] -> {:ok, profile_key}
      [] -> :error
    end
  end

  def get_session(_sid), do: :error

  @spec clear_all_sessions() :: :ok
  def clear_all_sessions do
    true = :ets.delete_all_objects(@sessions)
    :ok
  end

  @impl GenServer
  def init(:ok) do
    for table <- [@codes, @tokens, @sessions] do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    {:ok, %{}}
  end
end
