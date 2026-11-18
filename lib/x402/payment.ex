defmodule X402.Payment do
  @moduledoc """
  The client's `PAYMENT-SIGNATURE` header: decoded, typed and matched to an offer.

  Everything in the header is untrusted. `decode/2`:

    * refuses a header over 8 KB (`:header_too_large`) before decoding it;
    * refuses invalid base64 (`:invalid_base64`), invalid JSON
      (`:invalid_json`) and JSON that is not an object (`:not_an_object`);
    * refuses any `x402Version` but the integer 2 (`:unsupported_version`);
    * checks the type of every field it reads (`:invalid_payload`),
      creating no atoms from input.

  `match/2` then compares the client's `accepted` requirements with the offer
  field by field, as the x402 reference server does (`deepEqual` of the core
  fields, the offer's `extra` a subset of the client's), and hands the
  scheme-specific `payload` to the scheme module.

  The decoded JSON is kept as `raw` because the facilitator must receive the
  payload exactly as the client signed it (spec 7.1, `paymentPayload`).
  """

  alias X402.{Codec, Offer, Scheme}

  @enforce_keys [:accepted, :payload, :raw]
  defstruct [:accepted, :payload, :resource, :raw, :payer, :payment_id]

  @type t :: %__MODULE__{
          accepted: map(),
          payload: map(),
          resource: map() | nil,
          raw: map(),
          payer: String.t() | nil,
          payment_id: String.t() | nil
        }

  @type decode_error ::
          :header_too_large
          | :invalid_base64
          | :invalid_json
          | :not_an_object
          | :unsupported_version
          | :invalid_payload

  @type match_error ::
          :scheme_mismatch
          | :network_mismatch
          | :unsupported_scheme
          | :unsupported_asset_transfer_method
          | :asset_mismatch
          | :pay_to_mismatch
          | :amount_mismatch
          | :max_timeout_mismatch
          | :extra_mismatch
          | :resource_mismatch
          | :invalid_payload

  @doc "Decodes a `PAYMENT-SIGNATURE` header value. Options: `:max_bytes` (default 8,192)."
  @spec decode(term(), keyword()) :: {:ok, t()} | {:error, decode_error()}
  def decode(header, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, Codec.default_max_bytes())

    with {:ok, raw} <- Codec.decode(header, max_bytes),
         :ok <- version(raw),
         {:ok, accepted} <- accepted(raw["accepted"]),
         {:ok, payload} <- object(raw["payload"]),
         {:ok, resource} <- resource(raw["resource"]) do
      {:ok, %__MODULE__{accepted: accepted, payload: payload, resource: resource, raw: raw}}
    end
  end

  @doc """
  Checks a decoded payment against the offer.

  Every term must be equal: scheme, network, amount, asset, payTo,
  maxTimeoutSeconds, the offer's `extra` keys and the resource URL.
  Addresses compare by the scheme's rule (case-insensitive on EVM).
  On success the payment carries `payer` and `payment_id`.
  """
  @spec match(t(), Offer.t()) :: {:ok, t()} | {:error, match_error()}
  def match(%__MODULE__{accepted: a} = payment, %Offer{} = offer) do
    with :ok <- check(a["scheme"] == offer.scheme, :scheme_mismatch),
         :ok <- check(a["network"] == offer.network, :network_mismatch),
         {:ok, scheme} <- Scheme.for(offer.scheme, offer.network),
         :ok <- check(scheme.same_address?(a["asset"], offer.asset), :asset_mismatch),
         :ok <- check(scheme.same_address?(a["payTo"], offer.pay_to), :pay_to_mismatch),
         :ok <- check(a["amount"] == offer.amount, :amount_mismatch),
         :ok <- check(a["maxTimeoutSeconds"] == offer.max_timeout_seconds, :max_timeout_mismatch),
         :ok <- check(subset?(offer.extra, a["extra"] || %{}), :extra_mismatch),
         :ok <- check(resource_url(payment) == offer.resource, :resource_mismatch),
         {:ok, %{payer: payer, payment_id: id}} <- scheme.check_payload(a, payment.payload, offer) do
      {:ok, %{payment | payer: payer, payment_id: id}}
    end
  end

  # The spec lists `resource` as optional in a PaymentPayload, but the
  # reference client always copies it from PaymentRequired. We require it,
  # so a payment made for one URL is never spent on another.
  defp resource_url(%__MODULE__{resource: %{"url" => url}}) when is_binary(url), do: url
  defp resource_url(_), do: nil

  defp version(%{"x402Version" => 2}), do: :ok
  defp version(_), do: {:error, :unsupported_version}

  defp accepted(%{} = a) do
    typed? =
      is_binary(a["scheme"]) and is_binary(a["network"]) and is_binary(a["amount"]) and
        is_binary(a["asset"]) and is_binary(a["payTo"]) and is_integer(a["maxTimeoutSeconds"]) and
        (is_nil(a["extra"]) or is_map(a["extra"]))

    if typed?, do: {:ok, a}, else: {:error, :invalid_payload}
  end

  defp accepted(_), do: {:error, :invalid_payload}

  defp object(%{} = map), do: {:ok, map}
  defp object(_), do: {:error, :invalid_payload}

  defp resource(nil), do: {:ok, nil}

  defp resource(%{} = r) do
    if is_binary(r["url"]), do: {:ok, r}, else: {:error, :invalid_payload}
  end

  defp resource(_), do: {:error, :invalid_payload}

  # Every key the server put in `extra` must come back with the same value;
  # the client may add keys (reference: objectContainsSubset).
  defp subset?(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.all?(expected, fn {k, v} ->
      case Map.fetch(actual, k) do
        {:ok, av} when is_map(v) and is_map(av) -> subset?(v, av)
        {:ok, av} -> av === v
        :error -> false
      end
    end)
  end

  defp subset?(_, _), do: false

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
