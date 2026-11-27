defmodule MedFabric.Exam.AcquisitionReviews do
  @moduledoc "Native review orchestration. External mapping is deliberately independent of clinical acceptance."
  alias MedFabric.Exam.AcquisitionManifest
  alias MedFabric.Domain.Review
  alias MedFabric.Store.Records

  def review(context, enc, id, actor, digest, request_id, choice) do
    with {:ok, source} <- AcquisitionManifest.verify_review(context, enc, id, actor, digest),
         {:ok, plan} <- Review.plan(source, actor, request_id, choice, DateTime.utc_now()),
         {:ok, outcome} <- Records.accept_plan(context.db, plan) do
      MedFabric.Exam.announce(enc, context)
      {:ok, outcome}
    end
  end
end
