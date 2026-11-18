defmodule X402.Facilitator do
  @moduledoc """
  A facilitator verifies and settles payments (x402 v2 spec, section 7).

  Both calls take the same request body (spec 7.1, 7.2):

      %{
        "x402Version" => 2,
        "paymentPayload" => <the client's PaymentPayload, as decoded>,
        "paymentRequirements" => <the offer's PaymentRequirements>
      }

  built by `request/2`, and the adapter's config (a keyword list).

  Results:

    * `verify/2` → `{:ok, %{payer: String.t() | nil}}` when `isValid` is true.
    * `settle/2` → `{:ok, %X402.Settlement{}}` when `success` is true, the
      transaction hash is well formed and the network is the one we asked for.
    * `{:error, {:rejected, reason}}`: the facilitator answered and said no
      (`isValid: false` or `success: false`, on a 2xx or not). `reason` is the
      facilitator's reason code if it looks like one, else `"unknown"`.
    * `{:error, {:pending, tx_hash}}`: settle returned `settlement_pending`
      (spec 9): broadcast, not confirmed. Not a success.
    * `{:error, :timeout | :unavailable | {:http_status, status} |
      :invalid_response | :invalid_config | :req_options_not_allowed |
      :not_implemented}`: anything else.

  An adapter should return, not raise; `X402.handle/2` still catches a raise,
  throw or exit from either call and fails closed.

  Every outcome but `{:ok, _}` is an error; `X402.handle/2` fails closed on all of them.
  """

  alias X402.{Offer, Payment, Settlement}

  @type request :: map()
  @type error ::
          {:rejected, String.t()}
          | {:pending, String.t()}
          | :timeout
          | :unavailable
          | {:http_status, non_neg_integer()}
          | :invalid_response
          | :invalid_config
          | :req_options_not_allowed
          | :not_implemented

  @callback verify(request(), keyword()) :: {:ok, %{payer: String.t() | nil}} | {:error, error()}
  @callback settle(request(), keyword()) :: {:ok, Settlement.t()} | {:error, error()}

  @doc "The `/verify` and `/settle` request body for a payment against an offer."
  @spec request(Payment.t(), Offer.t()) :: request()
  def request(%Payment{raw: raw}, %Offer{} = offer) do
    %{
      "x402Version" => Offer.x402_version(),
      "paymentPayload" => raw,
      "paymentRequirements" => Offer.requirements(offer)
    }
  end
end
