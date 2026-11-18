defmodule X402.Settlement do
  @moduledoc """
  A successful settlement, as the facilitator reported it and we checked it.

  `transaction` is the on-chain transaction hash, `network` the CAIP-2 network
  (always equal to the offer's), `payer` the payer's address when known.

  `response_header/1` is the `PAYMENT-RESPONSE` value: base64 JSON of a
  `SettlementResponse` (spec 5.3). It is rebuilt from these checked fields, not
  copied from the facilitator, so nothing unchecked is reflected to the client.
  """

  alias X402.Codec

  @enforce_keys [:transaction, :network]
  defstruct [:transaction, :network, :payer, :amount, :payment_id]

  @type t :: %__MODULE__{
          transaction: String.t(),
          network: String.t(),
          payer: String.t() | nil,
          amount: String.t() | nil,
          payment_id: String.t() | nil
        }

  @doc "The `SettlementResponse` object, JSON-shaped."
  @spec to_response(t()) :: map()
  def to_response(%__MODULE__{} = s) do
    %{"success" => true, "transaction" => s.transaction, "network" => s.network}
    |> put_present("payer", s.payer)
    |> put_present("amount", s.amount)
  end

  @doc "The value of the `PAYMENT-RESPONSE` header."
  @spec response_header(t()) :: String.t()
  def response_header(%__MODULE__{} = s), do: s |> to_response() |> Codec.encode()

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
