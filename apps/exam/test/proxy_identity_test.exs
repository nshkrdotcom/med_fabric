defmodule MedFabric.ExamWeb.ProxyIdentityTest do
  use ExUnit.Case, async: true
  alias MedFabric.ExamWeb.ProxyIdentity

  test "remote sessions and media sockets require the authenticated proxy actor" do
    config = %{local?: false, proxy_secret: "secret"}
    headers = [{"x-exam-proxy-token", "secret"}, {"x-exam-actor", "alice"}]
    assert ProxyIdentity.matches?(headers, "alice", config)
    refute ProxyIdentity.matches?(headers, "bob", config)
    refute ProxyIdentity.matches?(tl(headers), "alice", config)
    refute ProxyIdentity.matches?(headers ++ [{"x-exam-actor", "alice"}], "alice", config)
  end
end
