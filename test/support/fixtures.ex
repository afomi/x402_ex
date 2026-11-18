defmodule X402.Fixtures do
  @moduledoc false

  # Values from the x402 v2 spec examples (Base Sepolia USDC).
  @asset "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
  @pay_to "0x209693Bc6afc0C5328bA36FaF03C514EF312287C"
  @payer "0x857b06519E91e3A54538791bDbb0E22373e36b66"
  @resource "https://example.org/data"
  @tx "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

  def asset, do: @asset
  def pay_to, do: @pay_to
  def payer, do: @payer
  def resource, do: @resource
  def tx, do: @tx

  def offer(overrides \\ %{}) do
    %{
      amount: 10_000,
      network: "eip155:84532",
      asset: @asset,
      extra: %{"name" => "USDC", "version" => "2"},
      pay_to: @pay_to,
      resource: @resource,
      description: "One page over the crawl budget",
      max_timeout_seconds: 60
    }
    |> Map.merge(overrides)
    |> X402.Offer.new!()
  end

  def nonce(n \\ 1) do
    "0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0")
  end

  @doc "A PaymentPayload map that matches `offer`; `fun` may alter it."
  def payment(offer, opts \\ []) do
    %{
      "x402Version" => 2,
      "resource" => %{"url" => offer.resource, "description" => offer.description},
      "accepted" => X402.Offer.requirements(offer),
      "payload" => %{
        "signature" => "0x" <> String.duplicate("ab", 65),
        "authorization" => %{
          "from" => Keyword.get(opts, :from, @payer),
          "to" => offer.pay_to,
          "value" => offer.amount,
          "validAfter" => "1740672089",
          "validBefore" => "1740672154",
          "nonce" => Keyword.get(opts, :nonce, nonce())
        }
      }
    }
  end

  def header(payment_map), do: X402.Codec.encode(payment_map)

  def verify_ok, do: %{"isValid" => true, "payer" => @payer}

  def settle_ok(tx \\ @tx) do
    %{"success" => true, "transaction" => tx, "network" => "eip155:84532", "payer" => @payer}
  end
end
