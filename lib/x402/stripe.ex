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

  Keys and networks: a live key (`sk_live_`, `rk_live_`) is refused for Base
  Sepolia, and a test key (`sk_test_`, `rk_test_`) for Base mainnet
  (`:key_network_mismatch`), so testnet USDC is never recorded as live revenue.

  The secret key may be a string or a 0-arity function returning one; a
  function keeps it out of any argument list a crash report could print. It
  is used for the `Authorization` header and nowhere else: never logged and
  never part of a return value. Stripe's error messages are not returned
  either (they can echo part of a key); only the HTTP status and Stripe's
  `type` and `code`.

  The idempotency key is the transaction hash, so retrying a record (as
  `X402.Reconciler` does) returns the same PaymentIntent. Stripe keeps
  idempotency keys for 24 hours.

  Options: `:stripe_version`, `:stripe_network` (overrides the network
  mapping), `:receive_timeout` (default 10,000 ms, also the deadline for the
  whole response), `:connect_timeout` (default 2,000 ms), `:req_options`
  (test seam, see `X402.HTTPClient`).
  """

  require Logger

  alias X402.{HTTPClient, Offer, Settlement}
  alias X402.Scheme.ExactEvm

  @url "https://api.stripe.com/v1/payment_intents"
  @default_version "2026-05-27.preview"
  @atomic_per_cent 10_000
  @code ~r/\A[a-z0-9_]{1,64}\z/

  # Stripe's crypto network name for each CAIP-2 network. Base Sepolia maps
  # to "base" too: Stripe's sandbox guide changes the deposit address and
  # the facilitator, not the PaymentIntent's network.
  @networks %{"eip155:8453" => "base", "eip155:84532" => "base"}
  @mainnets ["eip155:8453"]
  @testnets ["eip155:84532"]

  @doc "The default `Stripe-Version`."
  def default_version, do: @default_version

  @type secret :: String.t() | (-> String.t())

  @type error ::
          :invalid_secret_key
          | :key_network_mismatch
          | :invalid_transaction
          | :unsupported_network
          | :unsupported_asset
          | :amount_not_whole_cents
          | :timeout
          | :stripe_unavailable
          | :invalid_response
          | :req_options_not_allowed
          | {:stripe_error, non_neg_integer(), String.t() | nil, String.t() | nil}

  @doc """
  Creates the PaymentIntent for a settlement. Returns `{:ok, "pi_..."}`.

  Its second argument is what `X402.handle/2` gives `:on_settled`, so

      on_settled: &X402.Stripe.record(fn -> stripe_key() end, &1)

  records each payment, and `X402.handle/2` stores the returned id.
  """
  @spec record(
          secret(),
          %{required(:settlement) => Settlement.t(), required(:offer) => Offer.t()},
          keyword()
        ) ::
          {:ok, String.t()} | {:error, error()}
  def record(secret, %{settlement: %Settlement{} = s, offer: %Offer{} = offer}, opts \\ []) do
    record_payment(
      secret,
      %{tx_hash: s.transaction, network: offer.network, asset: offer.asset, amount: offer.amount},
      opts
    )
  end

  @doc """
  Creates the PaymentIntent from the stored facts of a payment:
  `%{tx_hash, network, asset, amount}`. Used by `X402.Reconciler`.
  """
  @spec record_payment(secret(), map(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def record_payment(
        secret,
        %{tx_hash: tx, network: network, asset: asset, amount: amount},
        opts \\ []
      ) do
    with {:ok, key} <- secret_key(secret),
         :ok <- key_matches_network(key, network),
         :ok <- if(ExactEvm.valid_transaction?(tx), do: :ok, else: {:error, :invalid_transaction}),
         {:ok, stripe_network} <- stripe_network(network, opts),
         :ok <- asset(network, asset),
         {:ok, cents} <- cents(amount) do
      tx = String.downcase(tx)
      post(key, form(cents, stripe_network, tx), tx, opts)
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

  defp post(key, body, tx_hash, opts) do
    timeout = Keyword.get(opts, :receive_timeout, 10_000)

    req = [
      method: :post,
      url: @url,
      headers: [
        {"authorization", "Bearer " <> key},
        {"stripe-version", Keyword.get(opts, :stripe_version, @default_version)},
        {"idempotency-key", tx_hash},
        {"content-type", "application/x-www-form-urlencoded"}
      ],
      body: URI.encode_query(body, :www_form),
      connect_options: [timeout: Keyword.get(opts, :connect_timeout, 2_000)],
      receive_timeout: timeout
    ]

    case HTTPClient.request(req,
           deadline_ms: timeout,
           req_options: Keyword.get(opts, :req_options, [])
         ) do
      {:ok, status, body} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, %{"id" => "pi_" <> _ = id}} ->
            Logger.info("x402 stripe recorded payment_intent=#{id} tx_hash=#{tx_hash}")
            {:ok, id}

          _ ->
            {:error, :invalid_response}
        end

      {:ok, status, body} ->
        {type, code} = stripe_error(body)

        Logger.warning(
          "x402 stripe refused tx_hash=#{tx_hash} status=#{status} type=#{type} code=#{code}"
        )

        {:error, {:stripe_error, status, type, code}}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :too_large} ->
        {:error, :invalid_response}

      {:error, :req_options_not_allowed} ->
        {:error, :req_options_not_allowed}

      {:error, _} ->
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

  defp secret_key(fun) when is_function(fun, 0), do: secret_key(fun.())
  defp secret_key("sk_" <> rest = key) when byte_size(rest) > 0, do: {:ok, key}
  defp secret_key("rk_" <> rest = key) when byte_size(rest) > 0, do: {:ok, key}
  defp secret_key(_), do: {:error, :invalid_secret_key}

  defp key_matches_network(key, network) do
    live? = String.starts_with?(key, ["sk_live_", "rk_live_"])
    test? = String.starts_with?(key, ["sk_test_", "rk_test_"])

    cond do
      live? and network in @testnets -> {:error, :key_network_mismatch}
      test? and network in @mainnets -> {:error, :key_network_mismatch}
      true -> :ok
    end
  end

  defp stripe_network(network, opts) do
    case Keyword.get(opts, :stripe_network) || Map.get(@networks, network) do
      nil -> {:error, :unsupported_network}
      stripe_network -> {:ok, stripe_network}
    end
  end

  defp asset(network, asset) do
    case ExactEvm.usdc(network) do
      {:ok, %{asset: usdc}} ->
        if ExactEvm.same_address?(usdc, asset), do: :ok, else: {:error, :unsupported_asset}

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
