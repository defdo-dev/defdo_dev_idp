defmodule Defdo.DevIdp.StoreTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Defdo.DevIdp.Store

  setup do
    start_supervised!(Store)
    :ok
  end

  defp code(expires_at), do: %{profile_key: :operator, expires_at: expires_at}

  test "a code is single use" do
    Store.put_code("c1", code(Store.now() + 60))

    assert {:ok, %{profile_key: :operator}} = Store.take_code("c1")
    assert Store.take_code("c1") == :error
  end

  test "an expired code is refused and gone" do
    Store.put_code("c2", code(100))

    assert Store.take_code("c2", 100) == :error
    assert Store.take_code("c2", 0) == :error
  end

  test "an unknown or non-string code is refused" do
    assert Store.take_code("nope") == :error
    assert Store.take_code(nil) == :error
  end

  test "a token is readable until it expires, then deleted" do
    Store.put_token("t1", %{profile_key: :operator, expires_at: 100})

    assert {:ok, _data} = Store.get_token("t1", 99)
    assert {:ok, _data} = Store.get_token("t1", 99)
    assert Store.get_token("t1", 100) == :error
    assert Store.get_token("t1", 0) == :error
  end

  test "sessions are cleared together" do
    Store.put_session("s1", :operator)
    Store.put_session("s2", :customer)

    assert Store.get_session("s1") == {:ok, :operator}
    assert Store.clear_all_sessions() == :ok
    assert Store.get_session("s1") == :error
    assert Store.get_session("s2") == :error
    assert Store.get_session(nil) == :error
  end

  test "random values are 32 bytes, URL-safe and distinct" do
    values = for _ <- 1..50, do: Store.random()

    assert Enum.uniq(values) == values
    assert Enum.all?(values, &(byte_size(Base.url_decode64!(&1, padding: false)) == 32))
  end

  # A model of the code table: put, take and the passing of time.
  property "each code is taken at most once, and only before it expires" do
    command =
      StreamData.one_of([
        StreamData.tuple(
          {StreamData.constant(:put), StreamData.integer(1..5), StreamData.integer(1..20)}
        ),
        StreamData.tuple({StreamData.constant(:take), StreamData.integer(1..5)}),
        StreamData.tuple({StreamData.constant(:tick), StreamData.integer(1..8)})
      ])

    check all(commands <- StreamData.list_of(command, max_length: 60)) do
      prefix = Store.random()

      Enum.reduce(commands, {%{}, 0}, fn
        {:put, key, ttl}, {model, now} ->
          Store.put_code(prefix <> Integer.to_string(key), code(now + ttl))
          {Map.put(model, key, now + ttl), now}

        {:take, key}, {model, now} ->
          expected =
            case Map.fetch(model, key) do
              {:ok, expires_at} when expires_at > now -> :ok
              _missing_or_expired -> :error
            end

          actual =
            case Store.take_code(prefix <> Integer.to_string(key), now) do
              {:ok, _data} -> :ok
              :error -> :error
            end

          assert actual == expected
          {Map.delete(model, key), now}

        {:tick, seconds}, {model, now} ->
          {model, now + seconds}
      end)
    end
  end
end
