defmodule MedFabric.Preview.FeedTest do
  use ExUnit.Case,async: false
  alias MedFabric.Preview.Endpoint
  test "private feed accepts only credentialed monitor frames and never retains listenerless frames" do
    f=%MedEx.Wire.FrameV1{stream_number: 3,source_epoch: 0,config_epoch: 1,sequence: 0,first_sample: 0,sample_count: 960,payload: :binary.copy(<<0>>,1920)}
    {:ok,bytes}=MedEx.Wire.FrameV1.encode(f)
    request=fn body->Plug.Test.conn(:post,"/feed",body) |> Plug.Conn.put_req_header("x-acquisition","fixture") end
    assert Endpoint.call(request.(bytes),[]).status==403
    signed=fn body->request.(body) |> Plug.Conn.put_req_header("authorization","Bearer synthetic-preview-test-credential") end
    assert Endpoint.call(signed.(bytes),[]).status==200
    assert :ets.lookup(:mf_preview_feed,"fixture")==[]
    {:ok,raw}=MedEx.Wire.FrameV1.encode(%{f | stream_number: 1})
    assert Endpoint.call(signed.(raw),[]).status==403
  end
end
