defmodule Folio.Clients.HTTPTest do
  use ExUnit.Case, async: true

  alias Folio.Clients.HTTP

  describe "retry?/2" do
    test "a rate limit is never retried - asking again only deepens the throttle" do
      refute HTTP.retry?(nil, %Req.Response{status: 429})
      refute HTTP.retry?(nil, %Req.Response{status: 999})
    end

    test "server-side and timeout statuses are retried" do
      for status <- [408, 500, 502, 503, 504] do
        assert HTTP.retry?(nil, %Req.Response{status: status})
      end
    end

    test "client errors and successes are not retried" do
      for status <- [200, 400, 404] do
        refute HTTP.retry?(nil, %Req.Response{status: status})
      end
    end

    test "transport exceptions are retried" do
      assert HTTP.retry?(nil, %Req.TransportError{reason: :closed})
    end
  end
end
