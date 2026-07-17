defmodule Latchkey.EventStore.UrlTest do
  use ExUnit.Case, async: true

  alias Latchkey.EventStore.Url

  describe "derive!/1" do
    test "strips the query string from a direct-endpoint URL" do
      url =
        "ecto://user:pass@ep-cool-name-123456.us-east-2.aws.neon.tech/latchkey?sslmode=require"

      assert Url.derive!(url) ==
               "ecto://user:pass@ep-cool-name-123456.us-east-2.aws.neon.tech/latchkey"
    end

    test "leaves a query-less direct-endpoint URL unchanged" do
      url = "ecto://user:pass@db.internal/latchkey"

      assert Url.derive!(url) == url
    end

    test "raises for a pooled (PgBouncer) endpoint" do
      url =
        "ecto://user:pass@ep-cool-name-123456-pooler.us-east-2.aws.neon.tech/latchkey?sslmode=require"

      assert_raise RuntimeError, ~r/pooled \(PgBouncer\) endpoint/, fn ->
        Url.derive!(url)
      end
    end

    test "the raise message names the offending host and the direct-endpoint fix" do
      url = "ecto://user:pass@ep-cool-name-123456-pooler.us-east-2.aws.neon.tech/latchkey"

      error = assert_raise RuntimeError, fn -> Url.derive!(url) end

      assert error.message =~ "ep-cool-name-123456-pooler.us-east-2.aws.neon.tech"
      assert error.message =~ "direct"
    end
  end

  describe "pooled?/1" do
    test "true when the host carries the -pooler suffix" do
      assert Url.pooled?("ep-cool-name-123456-pooler.us-east-2.aws.neon.tech")
    end

    test "false for a direct endpoint" do
      refute Url.pooled?("ep-cool-name-123456.us-east-2.aws.neon.tech")
    end

    test "false for a nil host" do
      refute Url.pooled?(nil)
    end
  end
end
