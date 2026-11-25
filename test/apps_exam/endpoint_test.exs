defmodule MedFabric.ExamWeb.EndpointTest do
  use ExUnit.Case, async: true

  alias MedFabric.ExamWeb.Endpoint

  test "an unknown browser route returns a 404 response" do
    conn = Endpoint.call(Plug.Test.conn(:get, "/missing"), [])

    assert conn.status == 404
    assert conn.resp_body =~ "Not Found"
  end
end
