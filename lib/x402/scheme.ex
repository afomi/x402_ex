defmodule X402.Scheme do
  @moduledoc """
  The one place a scheme and network are turned into rules.

  `for/2` maps a scheme name and a CAIP-2 network to the module that knows how
  that scheme works there. v0.1 knows one: `"exact"` on `eip155:*`
  (`X402.Scheme.ExactEvm`, EIP-3009 transfers only). A scheme for another
  network (BSV, say) is a new module implementing this behaviour plus one
  clause in `for/2`; `X402.Offer`, `X402.Payment` and `X402.handle/2` do not change.
  """

  alias X402.Offer

  @typedoc "What a scheme learns from a payment it accepts."
  @type checked :: %{payer: String.t(), payment_id: String.t()}

  @doc "Checks the scheme-specific parts of an offer (address formats, required `extra` keys)."
  @callback validate_offer(Offer.t()) :: :ok | {:error, atom()}

  @doc """
  Checks the scheme-specific parts of a payment against the offer: the
  client's `accepted` requirements (already matched field by field by
  `X402.Payment.match/2`) and its scheme-specific `payload`.

  Returns the payer and a `payment_id`: a string that names this payment
  authorization uniquely and is the same on every retry of it, used as the
  replay-guard key before settlement.
  """
  @callback check_payload(accepted :: map(), payload :: map(), Offer.t()) ::
              {:ok, checked()} | {:error, atom()}

  @doc "Whether a string is a well-formed address on this network."
  @callback valid_address?(term()) :: boolean()

  @doc "Whether two addresses on this network name the same account."
  @callback same_address?(String.t(), String.t()) :: boolean()

  @doc "Whether a settlement transaction id is well formed for this network."
  @callback valid_transaction?(term()) :: boolean()

  @doc "The module for a scheme on a network, or `{:error, :unsupported_scheme}`."
  @spec for(String.t(), String.t()) :: {:ok, module()} | {:error, :unsupported_scheme}
  def for("exact", "eip155:" <> chain_id) do
    if chain_id =~ ~r/\A[1-9][0-9]{0,19}\z/,
      do: {:ok, X402.Scheme.ExactEvm},
      else: {:error, :unsupported_scheme}
  end

  def for(_scheme, _network), do: {:error, :unsupported_scheme}
end
