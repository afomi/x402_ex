defmodule X402 do
  @moduledoc """
  x402 v2 payments for a Plug app: answer a request with a payable offer, and
  accept a payment for it exactly once.

      case X402.handle(conn,
             offer: offer,
             facilitator: {X402.Facilitator.X402Org, []},
             replay_guard: {MyApp.X402Claims, []},
             on_settled: &X402.Stripe.record(stripe_key, &1)
           ) do
        {:ok, conn, _settlement} ->
          serve(conn)

        {:payment_required, challenge} ->
          conn |> X402.put_challenge(challenge) |> send_resp(402, "{}")

        {:payment_required, challenge, _reason} ->
          conn |> X402.put_challenge(challenge) |> send_resp(402, "{}")

        {:error, _reason} ->
          send_resp(conn, 503, "")
      end

  ## The steps

  With no `PAYMENT-SIGNATURE` header: `{:payment_required, challenge}`, where
  `challenge` is the `PAYMENT-REQUIRED` header value.

  With one:

    1. decode it (`X402.Payment.decode/2`): size cap, base64, JSON, types;
    2. match it to the offer (`X402.Payment.match/2`): every term equal;
    3. verify it with the facilitator (`/verify`, read-only);
    4. claim its authorization in the replay guard (`"auth:" <> payment_id`);
    5. settle it with the facilitator (`/settle`, moves the money);
    6. claim the settlement's transaction (`"tx:" <> network <> ":" <> hash`);
    7. call `on_settled` (for example, record it in Stripe);
    8. return `{:ok, conn, settlement}`, `conn` carrying `PAYMENT-RESPONSE`.

  ## Why claim before settle

  A guard keyed on the transaction hash alone is not enough. In the
  `exact` EVM scheme there is no transaction hash until `/settle` has moved
  the money (spec 7.2; scheme_exact_evm.md, Phase 3), so a claim on the hash
  alone could only come after settlement, and two concurrent retries of one
  payment would both reach `/settle`. The chain would reject the second
  (EIP-3009 nonces are single-use), but how a facilitator reports that is its
  own business, and we would be trusting it to tell the two apart.

  So the key that is claimed first is the signed authorization itself:
  network, asset, payer and EIP-3009 nonce, all fixed by the client's
  signature and identical on every retry. Of concurrent retries, one claim
  wins and goes on to settle; the others are refused as `:replayed` before
  any money moves. Exactly one request is answered `:ok` per authorization.

  After settlement the transaction hash is claimed as well, so a facilitator
  that reported one transaction for two authorizations would be caught, and
  the app's table has the hash for reconciliation and for Stripe.

  This also follows the spec's flow (section 6.1, `authorization`): verify,
  which is read-only, comes before anything is committed. One difference: we
  settle before the app runs the resource, not after, so the app knows it has
  been paid before it does the work.

  ## Failing closed

  Claims are never released. If settlement fails, times out or comes back
  `settlement_pending`, the authorization stays claimed and the client must
  sign a new one; the same header is refused as `:replayed`. A timeout during
  settle may still have moved money: such a case is logged with the payer,
  and a pending one with the transaction hash, for the app to reconcile.

  Results:

    * `{:payment_required, challenge, reason}` for a refusal the client can
      act on: a header that does not decode (`:header_too_large`,
      `:invalid_base64`, `:invalid_json`, `:not_an_object`,
      `:unsupported_version`, `:invalid_payload`, `:multiple_payment_headers`),
      a mismatch (`:scheme_mismatch`, `:network_mismatch`, `:amount_mismatch`,
      `:asset_mismatch`, `:pay_to_mismatch`, `:resource_mismatch`,
      `:max_timeout_mismatch`, `:extra_mismatch`,
      `:unsupported_asset_transfer_method`), `:verification_failed`,
      `:replayed`, `:settlement_failed` or `:settlement_pending`.
      The spec answers a malformed payload with 400 (transports-v2/http.md,
      "Error Handling"); an app may do so for the decode reasons.
    * `{:error, :facilitator_unavailable}` when the facilitator could not be
      reached, timed out, answered non-2xx without a verdict, or answered
      something we could not parse. Answer 503 (or 402) with no content.
    * `{:error, :replay_guard_unavailable}` when the guard returned anything
      but `:ok` or `{:error, :replayed}`. Same answer.

  `on_settled` runs after the payment is final. Its result does not change
  the outcome: an `{:error, _}` or a raise is logged, and the client, who has
  paid, still gets `{:ok, ...}`.

  ## Logging

  Only the outcome, the payer address and the transaction hash are logged;
  never a header, a signature or a key.
  """

  require Logger

  alias X402.{Facilitator, Offer, Payment, Settlement}

  @payment_header "payment-signature"
  @challenge_header "payment-required"
  @response_header "payment-response"

  @doc "The request header carrying the client's payment (`PAYMENT-SIGNATURE`), lowercased for Plug."
  def payment_header, do: @payment_header

  @doc "The response header carrying the offer (`PAYMENT-REQUIRED`), lowercased for Plug."
  def challenge_header, do: @challenge_header

  @doc "The response header carrying the settlement (`PAYMENT-RESPONSE`), lowercased for Plug."
  def response_header, do: @response_header

  @doc "Puts the `PAYMENT-REQUIRED` header on a response."
  @spec put_challenge(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_challenge(conn, challenge),
    do: Plug.Conn.put_resp_header(conn, @challenge_header, challenge)

  @type result ::
          {:ok, Plug.Conn.t(), Settlement.t()}
          | {:payment_required, String.t()}
          | {:payment_required, String.t(), atom()}
          | {:error, :facilitator_unavailable | :replay_guard_unavailable}

  @doc """
  Runs the payment steps for one request. See the moduledoc.

  Options:

    * `:offer` (required): an `X402.Offer`.
    * `:facilitator` (required): `{module, config}`, a `X402.Facilitator`.
    * `:replay_guard` (required): `{module, config}`, a `X402.ReplayGuard`.
    * `:on_settled`: a 1-arity function given
      `%{settlement: settlement, offer: offer, payer: payer}`.
    * `:max_header_bytes`: the cap on the payment header (default 8,192).
  """
  @spec handle(Plug.Conn.t(), keyword()) :: result()
  def handle(%Plug.Conn{} = conn, opts) do
    %Offer{} = offer = Keyword.fetch!(opts, :offer)
    {_, _} = facilitator = Keyword.fetch!(opts, :facilitator)
    {_, _} = guard = Keyword.fetch!(opts, :replay_guard)

    case Plug.Conn.get_req_header(conn, @payment_header) do
      [] ->
        {:payment_required, Offer.challenge_header(offer, "PAYMENT-SIGNATURE header is required")}

      [header] ->
        pay(conn, header, offer, facilitator, guard, opts)

      [_, _ | _] ->
        refuse(offer, :multiple_payment_headers, nil)
    end
  end

  defp pay(conn, header, offer, facilitator, guard, opts) do
    decode_opts = Keyword.take(opts, [:max_header_bytes]) |> rename(:max_header_bytes, :max_bytes)

    with {:ok, payment} <- step(Payment.decode(header, decode_opts), offer, nil),
         {:ok, payment} <- step(Payment.match(payment, offer), offer, nil),
         request = Facilitator.request(payment, offer),
         :ok <- verify(facilitator, request, offer, payment),
         :ok <-
           claim(
             guard,
             "auth:" <> payment.payment_id,
             meta(:authorization, payment, offer),
             offer
           ),
         {:ok, settlement} <- settle(facilitator, request, offer, payment),
         :ok <- claim_tx(guard, settlement, payment, offer) do
      settled(settlement, payment, offer, opts)
      Logger.info(log("paid", payment.payer, settlement.transaction))

      {:ok,
       Plug.Conn.put_resp_header(conn, @response_header, Settlement.response_header(settlement)),
       settlement}
    end
  end

  defp step({:ok, _} = ok, _offer, _payer), do: ok
  defp step({:error, reason}, offer, payer), do: refuse(offer, reason, payer)

  defp verify({module, config}, request, offer, payment) do
    case module.verify(request, config) do
      {:ok, _} ->
        :ok

      {:error, {:rejected, why}} ->
        Logger.info(log("verification_failed", payment.payer, nil) <> " reason=#{code(why)}")
        refuse(offer, :verification_failed, :logged)

      {:error, why} ->
        unavailable("verify", why, payment)
    end
  end

  defp settle({module, config}, request, offer, payment) do
    case module.settle(request, config) do
      {:ok, %Settlement{} = s} ->
        {:ok, %{s | payer: s.payer || payment.payer, payment_id: payment.payment_id}}

      {:error, {:rejected, why}} ->
        Logger.warning(log("settlement_failed", payment.payer, nil) <> " reason=#{code(why)}")
        refuse(offer, :settlement_failed, :logged)

      {:error, {:pending, tx}} ->
        Logger.error(log("settlement_pending", payment.payer, code(tx)) <> " reconcile=on_chain")
        refuse(offer, :settlement_pending, :logged)

      {:error, why} ->
        Logger.error(
          log("settle_unavailable", payment.payer, nil) <>
            " reason=#{short(why)} reconcile=check_payer_on_chain"
        )

        {:error, :facilitator_unavailable}
    end
  end

  defp claim({module, config}, key, meta, offer) do
    case module.claim(key, meta, config) do
      :ok ->
        :ok

      {:error, :replayed} ->
        Logger.info(log("replayed", meta.payer, meta.tx_hash))
        refuse(offer, :replayed, :logged)

      _other ->
        Logger.error(log("replay_guard_unavailable", meta.payer, meta.tx_hash))
        {:error, :replay_guard_unavailable}
    end
  end

  # A transaction hash already claimed means the facilitator reported one
  # transaction for two different authorizations. Refuse, and say so loudly.
  defp claim_tx(guard, settlement, payment, offer) do
    key = "tx:" <> settlement.network <> ":" <> String.downcase(settlement.transaction)

    case claim(guard, key, meta(:transaction, payment, offer, settlement.transaction), offer) do
      :ok ->
        :ok

      other ->
        Logger.error(log("transaction_already_claimed", payment.payer, settlement.transaction))
        other
    end
  end

  defp settled(settlement, payment, offer, opts) do
    case Keyword.get(opts, :on_settled) do
      nil ->
        :ok

      fun when is_function(fun, 1) ->
        try do
          case fun.(%{settlement: settlement, offer: offer, payer: payment.payer}) do
            {:error, why} ->
              Logger.error(
                log("on_settled_failed", payment.payer, settlement.transaction) <>
                  " reason=#{short(why)}"
              )

            _ ->
              :ok
          end
        rescue
          e ->
            Logger.error(
              log("on_settled_raised", payment.payer, settlement.transaction) <>
                " exception=#{inspect(e.__struct__)}"
            )
        end
    end
  end

  defp meta(kind, payment, offer, tx_hash \\ nil) do
    %{
      kind: kind,
      network: offer.network,
      payer: payment.payer,
      amount: offer.amount,
      resource: offer.resource,
      tx_hash: tx_hash
    }
  end

  defp unavailable(op, why, payment) do
    Logger.error(log("#{op}_unavailable", payment.payer, nil) <> " reason=#{short(why)}")
    {:error, :facilitator_unavailable}
  end

  defp refuse(offer, reason, payer) do
    if payer != :logged, do: Logger.info(log(Atom.to_string(reason), payer, nil))
    {:payment_required, Offer.challenge_header(offer, Atom.to_string(reason)), reason}
  end

  defp log(outcome, payer, tx_hash) do
    "x402 outcome=#{outcome} payer=#{payer || "-"} tx_hash=#{tx_hash || "-"}"
  end

  # Reasons come from adapters as atoms or small tuples; never print a
  # structure that might carry a request.
  defp short(why) when is_atom(why), do: Atom.to_string(why)
  defp short({tag, n}) when is_atom(tag) and is_integer(n), do: "#{tag}_#{n}"
  defp short({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp short(_), do: "other"

  # A facilitator adapter's reason or hash, printed only if it is a plain token.
  defp code(s) when is_binary(s), do: if(s =~ ~r/\A[A-Za-z0-9_]{1,128}\z/, do: s, else: "unknown")
  defp code(_), do: "unknown"

  defp rename(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put(opts, to, value)
    end
  end
end
