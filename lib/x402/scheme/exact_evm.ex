defmodule X402.Scheme.ExactEvm do
  @moduledoc """
  The `exact` scheme on EVM networks (`eip155:*`), EIP-3009 transfers only.

  Source: `specs/schemes/exact/scheme_exact_evm.md` in the x402 repo
  (docs/SPEC_NOTES.md, "exact on EVM"). The payload is
  `%{"signature" => hex, "authorization" => %{"from", "to", "value",
  "validAfter", "validBefore", "nonce"}}`.

  This module checks what can be checked without a chain: shapes, that
  `authorization.to` is the offer's `payTo` and that `authorization.value`
  is exactly the offer's amount. The signature, balance and validity window
  are the facilitator's `/verify` (spec Phase 2); we do not recover signatures.

  Permit2 and ERC-7710 transfers are refused (`:unsupported_asset_transfer_method`)
  in v0.1: their payloads differ and their replay keys need separate thought.

  EVM addresses are hex; letter case carries only the EIP-55 checksum, so
  addresses compare case-insensitively. The x402 reference facilitator does
  the same by normalising with viem's `getAddress` before comparing.
  """

  @behaviour X402.Scheme

  @address ~r/\A0x[0-9a-fA-F]{40}\z/
  @nonce ~r/\A0x[0-9a-fA-F]{64}\z/
  @tx_hash ~r/\A0x[0-9a-fA-F]{64}\z/
  # A 65-byte ECDSA signature is 130 hex digits. Smart-wallet signatures
  # (EIP-1271, EIP-6492) are longer; the header cap bounds them.
  @signature ~r/\A0x(?:[0-9a-fA-F]{2}){65,}\z/
  @uint ~r/\A(?:0|[1-9][0-9]{0,77})\z/

  @usdc %{
    "eip155:8453" => %{
      asset: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      extra: %{"name" => "USD Coin", "version" => "2"}
    },
    "eip155:84532" => %{
      asset: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
      extra: %{"name" => "USDC", "version" => "2"}
    }
  }

  @doc """
  USDC's contract and EIP-712 domain on Base (`"eip155:8453"`) and Base Sepolia
  (`"eip155:84532"`), from the x402 reference `defaultAssets.ts`.
  """
  @spec usdc(String.t()) :: {:ok, %{asset: String.t(), extra: map()}} | :error
  def usdc(network), do: Map.fetch(@usdc, network)

  @impl true
  def validate_offer(offer) do
    cond do
      not address?(offer.asset) -> {:error, :invalid_asset}
      not address?(offer.pay_to) -> {:error, :invalid_pay_to}
      not is_binary(offer.extra["name"]) -> {:error, :missing_extra_name}
      not is_binary(offer.extra["version"]) -> {:error, :missing_extra_version}
      not eip3009?(offer.extra) -> {:error, :unsupported_asset_transfer_method}
      true -> :ok
    end
  end

  @impl true
  def check_payload(accepted, payload, offer) when is_map(payload) do
    with :ok <- check(eip3009?(accepted["extra"]), :unsupported_asset_transfer_method),
         {:ok, auth} <- authorization(payload),
         :ok <- signature(payload),
         :ok <- check(same_address?(auth["to"], offer.pay_to), :pay_to_mismatch),
         :ok <- check(auth["value"] == offer.amount, :amount_mismatch) do
      {:ok,
       %{
         payer: auth["from"],
         payment_id: payment_id(offer, auth)
       }}
    end
  end

  def check_payload(_accepted, _payload, _offer), do: {:error, :invalid_payload}

  @doc """
  Whether the client's `accepted.extra` names a transfer method we support.

  Absent means the default, `"eip3009"` (spec: "If no `assetTransferMethod`
  is specified ... clients should default to `\"eip3009\"`").
  """
  def eip3009?(extra) when is_map(extra) do
    Map.get(extra, "assetTransferMethod", "eip3009") == "eip3009"
  end

  def eip3009?(_), do: true

  @impl true
  def valid_address?(s), do: address?(s)

  @impl true
  def same_address?(a, b) when is_binary(a) and is_binary(b) do
    address?(a) and address?(b) and String.downcase(a) == String.downcase(b)
  end

  def same_address?(_, _), do: false

  @impl true
  def valid_transaction?(tx) when is_binary(tx), do: tx =~ @tx_hash
  def valid_transaction?(_), do: false

  # EIP-3009 nonces are single-use per (token contract, authorizer), so
  # network + asset + from + nonce names one authorization for good.
  defp payment_id(offer, auth) do
    Enum.join(
      [
        "exact",
        offer.network,
        String.downcase(offer.asset),
        String.downcase(auth["from"]),
        String.downcase(auth["nonce"])
      ],
      ":"
    )
  end

  defp authorization(%{"authorization" => auth}) when is_map(auth) do
    cond do
      not address?(auth["from"]) -> {:error, :invalid_payload}
      not address?(auth["to"]) -> {:error, :invalid_payload}
      not uint?(auth["value"]) -> {:error, :invalid_payload}
      not uint?(auth["validAfter"]) -> {:error, :invalid_payload}
      not uint?(auth["validBefore"]) -> {:error, :invalid_payload}
      not (is_binary(auth["nonce"]) and auth["nonce"] =~ @nonce) -> {:error, :invalid_payload}
      true -> {:ok, auth}
    end
  end

  defp authorization(_), do: {:error, :invalid_payload}

  defp signature(%{"signature" => sig}) when is_binary(sig) do
    if sig =~ @signature, do: :ok, else: {:error, :invalid_payload}
  end

  defp signature(_), do: {:error, :invalid_payload}

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp address?(s) when is_binary(s), do: s =~ @address
  defp address?(_), do: false

  defp uint?(s) when is_binary(s), do: s =~ @uint
  defp uint?(_), do: false
end
