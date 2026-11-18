defmodule X402.Stripe do
  @moduledoc """
  Records a settled x402 payment in Stripe as a PaymentIntent.

  The request is the one in Stripe's x402 guide and the
  stripe-samples/machine-payments x402 server (docs/SPEC_NOTES.md, "Stripe"):

      POST https://api.stripe.com/v1/payment_intents
      Authorization: Bearer <secret key>
      Stripe-Version: 2026-05-27.preview
      Idempotency-Key: <on-chain transaction hash>

      amount=<cents>
      currency=usd
      confirm=true
      payment_method_data[type]=crypto
      allowed_payment_method_types[0]=crypto
      payment_method_options[crypto][mode]=transaction_verification
      payment_method_options[crypto][transaction_verification_options][network]=base
      payment_method_options[crypto][transaction_verification_options][transaction_hash]=<tx hash>

  Amounts: the offer's amount is USDC atomic units (6 decimals), so 10,000 is
  one cent. The sample rounds to the nearest cent and skips anything under a
  cent; we instead refuse an amount that is not a whole number of cents
  (`:amount_not_whole_cents`), so Stripe never records a sum the payer did
  not pay. Only USDC on Base and Base Sepolia is accepted (`:unsupported_asset`).

  The secret key is used for the `Authorization` header and nowhere else: it
  is never logged and never part of a return value. Stripe's error messages
  are not returned either (they can echo part of a key); only the HTTP
  status and Stripe's `type` and `code`.

  Options: `:stripe_version`, `:stripe_network` (overrides the network
  mapping), `:receive_timeout` (default 10,000 ms), `:req_options`.
  """

  require Logger

  alias X402.{Offer, Settlement}
  alias X402.Scheme.ExactEvm

  @url "https://api.stripe.com/v1/payment_intents"
  @default_version "2026-05-27.preview"
  @atomic_per_cent 10_000
  @code ~r/\A[a-z0-9_]{1,64}\z/

  # Stripe's crypto network name for each CAIP-2 network. Base Sepolia maps
  # to "base" too: Stripe's sandbox guide creates its deposit address with
  # network=base. UNCONFIRMED for transaction_verification_options.network.
  @networks %{"eip155:8453" => "base", "eip155:84532" => "base"}

  @doc "The default `Stripe-Version`."
  def default_version, do: @default_version

  @type error ::
          :invalid_secret_key
          | :invalid_transaction
          | :unsupported_network
          | :unsupported_asset
          | :amount_not_whole_cents
          | :timeout
          | :stripe_unavailable
          | :invalid_response
          | {:stripe_error, non_neg_integer(), String.t() | nil, String.t() | nil}

  @doc """
  Creates the PaymentIntent for a settlement. Returns `{:ok, "pi_..."}`.

      X402.Stripe.record(secret_key, %{settlement: settlement, offer: offer})
  """
  @spec record(String.t(), %{settlement: Settlement.t(), offer: Offer.t()}, keyword()) ::
          {:ok, String.t()} | {:error, error()}
  def record(secret_key, %{settlement: %Settlement{} = s, offer: %Offer{} = offer}, opts \\ []) do
    with :ok <- secret_key(secret_key),
         :ok <-
           if(ExactEvm.valid_transaction?(s.transaction),
             do: :ok,
             else: {:error, :invalid_transaction}
           ),
         {:ok, network} <- network(offer, opts),
         :ok <- asset(offer),
         {:ok, cents} <- cents(offer.amount) do
      body = form(cents, network, s.transaction)
      post(secret_key, body, s.transaction, opts)
    end
  end

  @doc "The form body, as ordered `{key, value}` pairs (exposed for tests and review)."
  @spec form(pos_integer(), String.t(), String.t()) :: [{String.t(), String.t()}]
  def form(cents, network, tx_hash) do
    opts = "payment_method_options[crypto]"

    [
      {"amount", Integer.to_string(cents)},
      {"currency", "usd"},
      {"confirm", "true"},
      {"payment_method_data[type]", "crypto"},
      {"allowed_payment_method_types[0]", "crypto"},
      {opts <> "[mode]", "transaction_verification"},
      {opts <> "[transaction_verification_options][network]", network},
      {opts <> "[transaction_verification_options][transaction_hash]", tx_hash}
    ]
  end

  defp post(secret_key, body, tx_hash, opts) do
    req =
      Req.new(
        method: :post,
        url: @url,
        headers: [
          {"authorization", "Bearer " <> secret_key},
          {"stripe-version", Keyword.get(opts, :stripe_version, @default_version)},
          {"idempotency-key", tx_hash},
          {"content-type", "application/x-www-form-urlencoded"}
        ],
        body: URI.encode_query(body, :www_form),
        retry: false,
        redirect: false,
        decode_body: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
      )
      |> Req.merge(Keyword.get(opts, :req_options, []))

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, %{"id" => "pi_" <> _ = id}} ->
            Logger.info("x402 stripe recorded payment_intent=#{id} tx_hash=#{tx_hash}")
            {:ok, id}

          _ ->
            {:error, :invalid_response}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {type, code} = stripe_error(body)

        Logger.warning(
          "x402 stripe refused tx_hash=#{tx_hash} status=#{status} type=#{type} code=#{code}"
        )

        {:error, {:stripe_error, status, type, code}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _exception} ->
        {:error, :stripe_unavailable}
    end
  end

  defp stripe_error(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{} = e}} -> {safe(e["type"]), safe(e["code"])}
      _ -> {nil, nil}
    end
  end

  defp safe(s) when is_binary(s), do: if(s =~ @code, do: s, else: nil)
  defp safe(_), do: nil

  defp secret_key("sk_" <> rest) when byte_size(rest) > 0, do: :ok
  defp secret_key("rk_" <> rest) when byte_size(rest) > 0, do: :ok
  defp secret_key(_), do: {:error, :invalid_secret_key}

  defp network(offer, opts) do
    case Keyword.get(opts, :stripe_network) || Map.get(@networks, offer.network) do
      nil -> {:error, :unsupported_network}
      network -> {:ok, network}
    end
  end

  defp asset(offer) do
    case ExactEvm.usdc(offer.network) do
      {:ok, %{asset: usdc}} ->
        if ExactEvm.same_address?(usdc, offer.asset), do: :ok, else: {:error, :unsupported_asset}

      :error ->
        {:error, :unsupported_asset}
    end
  end

  defp cents(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {atomic, ""} when atomic > 0 and rem(atomic, @atomic_per_cent) == 0 ->
        {:ok, div(atomic, @atomic_per_cent)}

      _ ->
        {:error, :amount_not_whole_cents}
    end
  end

  defp cents(_), do: {:error, :amount_not_whole_cents}
end
