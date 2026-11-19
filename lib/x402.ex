defmodule X402 do
  @moduledoc """
  x402 v2 payments for a Plug app: answer a request with a payable offer, and
  accept a payment for it exactly once.

      case X402.handle(conn,
             offer: offer,
             scope: [app: "bitblocks", pay_to: deposit_address],
             facilitator: {X402.Facilitator.X402Org, []},
             replay_guard: {MyApp.X402Claims, []},
             on_settled: &X402.Stripe.record(fn -> stripe_key() end, &1)
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

  Rate-limit the paid path per client before calling `handle/2`: every
  well-formed header costs a facilitator `/verify` call.

  ## The steps

  With no `PAYMENT-SIGNATURE` header: `{:payment_required, challenge}`, where
  `challenge` is the `PAYMENT-REQUIRED` header value.

  With one:

    1. decode it (`X402.Payment.decode/2`): size cap, base64, JSON, types;
    2. match it to the offer (`X402.Payment.match/2`): every term equal;
    3. verify it with the facilitator (`/verify`, read-only);
    4. claim its authorization in the replay guard (`"auth:" <> payment_id`);
    5. settle it with the facilitator (`/settle`, moves the money);
    6. claim the settlement's transaction (`"tx:" <> network <> ":" <> hash`),
       the durable record, before anything else can fail;
    7. call `on_settled` (for example, record it in Stripe), and store the
       PaymentIntent id it returns on the `"tx:"` row;
    8. return `{:ok, conn, settlement}`, `conn` carrying `PAYMENT-RESPONSE`.

  Steps 5 to 7 run in a process under `X402.TaskSupervisor`, not linked to
  the request, which waits for it. A client that disconnects mid-settle
  kills its request process; the settlement and its record still complete.
  The process carries the request's Logger metadata, and gets 30 seconds to
  finish when the app shuts down, so a deploy does not cut a settle short.

  A request that waits longer than `:settle_await_ms` gets
  `{:error, :facilitator_unavailable}` (answer 503), while the work carries
  on. That 503 may still mean "paid": the settlement can complete and be
  recorded after the client has gone. The `"tx:"` row and
  `X402.Reconciler` cover it; the client's retry with the same header is
  refused as `:replayed`, and it signs a new payment.

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

  ## One deposit address per app

  The exactly-once boundary is one guard table. Two apps with separate tables
  that share a `payTo` could each claim and serve one authorization, if a
  facilitator answered a repeated settle with the original hash. So each app
  must use its own deposit address, and `:scope` makes that explicit: it
  names the app and its one deposit address, and `handle/2` raises
  `ArgumentError` for an offer paying anyone else. The claim rows carry the
  app name.

  ## After the money moves

  Once `/settle` succeeds, no failure leaves the payment unrecorded, and
  only a report we cannot believe leaves it unserved:

    * a guard error on the `"tx:"` claim (not `:replayed`) still serves the
      client, and logs `outcome=tx_claim_failed` with the hash at error level;
    * an `on_settled` that returns an error, raises, throws or exits is
      logged; the client, who has paid, still gets `{:ok, ...}`, and the row
      stays without a PaymentIntent for `X402.Reconciler` to record;
    * a success whose `payer` or `amount` contradicts the signed payment is
      not served (`{:error, :facilitator_unavailable}`), but its `"tx:"` row
      is written with `kind: :transaction_disputed` and `dispute:
      :payer_mismatch | :amount_mismatch`, and logged as
      `outcome=settle_inconsistent`. The reconciler does not book it to
      Stripe; it needs a person and a check on chain.

  A settlement is checked the same way whichever adapter returned it: a
  transaction hash that is not well formed for the scheme, or a network other
  than the offer's, is not served (`{:error, :facilitator_unavailable}`) and
  is logged as `outcome=settle_unavailable` with `reason=invalid_transaction`
  or `reason=settlement_network_mismatch` and `reconcile=check_payer_on_chain`;
  nothing it reports can be keyed or recorded. A well-formed hash is
  lowercased once, so the `"tx:"` key, the row, Stripe's idempotency key and
  `PAYMENT-RESPONSE` all carry the same form.

  Before it succeeds, a facilitator adapter that raises, throws or exits is
  treated as the facilitator being unavailable, and fails closed.

  ## settlement_pending: one retry

  A `/settle` that answers `settlement_pending` has broadcast a transaction
  and names its hash (spec 9, non-terminal). `handle/2` then calls `/settle`
  once more, with the same request body, in the same settle task and under
  the same `"auth:"` claim, as the reference server does. The chain spends
  an EIP-3009 nonce once, so the second call cannot move the money twice,
  and the one claim still means one answer per authorization. The retry is
  given what is left of the first call's settle budget (the adapter's
  `:settle_timeout`, 15 s by default), never less than 5 s, so settle, retry
  and the Stripe record fit `:settle_await_ms`.

  Only a success naming the pending hash is served. A success naming
  another hash is the one answer that could book the wrong transaction, so
  it is written as a `"tx:"` row keyed on the pending hash with
  `kind: :transaction_disputed` and `dispute: :pending_hash_changed`, logged
  as `outcome=pending_hash_changed` with both hashes, and not served. A
  second `settlement_pending`, or a refusal after the broadcast, is refused
  as `:settlement_pending` with the hash logged (`reconcile=on_chain`). A
  retry that times out, crashes or cannot be read fails closed, logged as
  `outcome=settle_retry_unavailable` with the hash. A pending answer with no
  well-formed hash is not retried.

  ## Failing closed

  Claims are never released. If settlement fails, times out or is still
  `settlement_pending` after the retry, the authorization stays claimed and
  the client must sign a new one; the same header is refused as `:replayed`.
  A timeout during settle may still have moved money: such a case is logged
  with the payer, and a pending one with the transaction hash, for the app
  to reconcile (`X402.Reconciler`, "What it does not cover").

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
      reached, timed out, answered non-2xx without a verdict, answered
      something we could not parse or that contradicts the signed payment
      (another payer or amount), or its adapter crashed. Answer 503 (or 402)
      with no content.
    * `{:error, :replay_guard_unavailable}` when the guard could not make the
      `"auth:"` claim. Same answer.

  ## Logging

  Only the outcome, the payer address and the transaction hash are logged;
  never a header, a signature or a key. Decode refusals log at debug level,
  since crawlers send many.
  """

  require Logger

  alias X402.{Facilitator, Offer, Payment, Safe, Scheme, Settlement}

  @payment_header "payment-signature"
  @challenge_header "payment-required"
  @response_header "payment-response"

  # How long a settle in flight gets to finish when the app shuts down (a
  # deploy): a settle may take 15 s and the Stripe record up to 12 s more.
  @settle_shutdown_ms 30_000

  # The least the one retry of /settle after settlement_pending is given,
  # whatever is left of the first call's budget.
  @retry_floor_ms 5_000

  @doc false
  def settle_shutdown_ms, do: @settle_shutdown_ms

  @decode_reasons [
    :header_too_large,
    :invalid_base64,
    :invalid_json,
    :not_an_object,
    :unsupported_version,
    :invalid_payload,
    :multiple_payment_headers
  ]

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
    * `:scope` (required): `[app: name, pay_to: deposit_address]`, this app
      and its one deposit address. An offer to any other address raises.
    * `:facilitator` (required): `{module, config}`, a `X402.Facilitator`.
    * `:replay_guard` (required): `{module, config}`, a `X402.ReplayGuard`.
    * `:on_settled`: a 1-arity function given
      `%{settlement: settlement, offer: offer, payer: payer}`. If it returns
      `{:ok, "pi_..."}`, the id is stored on the `"tx:"` row.
    * `:max_header_bytes`: the cap on the payment header (default 8,192).
    * `:settle_await_ms`: how long the request waits for settle and record
      (default 40,000). Past it the request gets
      `{:error, :facilitator_unavailable}` and the work carries on.

  A missing or invalid option raises `ArgumentError` naming the option, and
  never its value (a facilitator config may hold a secret).
  """
  @spec handle(Plug.Conn.t(), keyword()) :: result()
  def handle(%Plug.Conn{} = conn, opts) when is_list(opts) do
    offer = option!(opts, :offer, &match?(%Offer{}, &1))
    facilitator = option!(opts, :facilitator, &adapter?/1)
    guard = option!(opts, :replay_guard, &adapter?/1)
    app = check_scope!(option!(opts, :scope, &Keyword.keyword?/1), offer)

    ctx = %{
      offer: offer,
      app: app,
      facilitator: facilitator,
      guard: guard,
      on_settled: option(opts, :on_settled, &is_function(&1, 1)),
      max_bytes: option(opts, :max_header_bytes, &(is_integer(&1) and &1 > 0)),
      await_ms: option(opts, :settle_await_ms, &(is_integer(&1) and &1 > 0)) || 40_000
    }

    case Plug.Conn.get_req_header(conn, @payment_header) do
      [] ->
        {:payment_required, Offer.challenge_header(offer, "PAYMENT-SIGNATURE header is required")}

      [header] ->
        pay(conn, header, ctx)

      [_, _ | _] ->
        refuse(offer, :multiple_payment_headers, nil)
    end
  end

  defp option!(opts, key, valid?) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if valid?.(value),
          do: value,
          else: raise(ArgumentError, "X402.handle/2: invalid #{inspect(key)}")

      :error ->
        raise ArgumentError, "X402.handle/2: missing #{inspect(key)}"
    end
  end

  defp option(opts, key, valid?) do
    case Keyword.fetch(opts, key) do
      {:ok, nil} ->
        nil

      {:ok, value} ->
        if valid?.(value),
          do: value,
          else: raise(ArgumentError, "X402.handle/2: invalid #{inspect(key)}")

      :error ->
        nil
    end
  end

  defp adapter?({module, _config}) when is_atom(module), do: true
  defp adapter?(_), do: false

  defp check_scope!(scope, offer) do
    app = Keyword.get(scope, :app)
    pay_to = Keyword.get(scope, :pay_to)

    unless is_binary(app) and app != "" and is_binary(pay_to) do
      raise ArgumentError, "X402.handle/2: :scope needs :app and :pay_to"
    end

    {:ok, scheme} = Scheme.for(offer.scheme, offer.network)

    unless scheme.same_address?(offer.pay_to, pay_to) do
      raise ArgumentError,
            "X402.handle/2: the offer's pay_to is not the deposit address of app #{inspect(app)}"
    end

    app
  end

  defp pay(conn, header, ctx) do
    decode_opts = if ctx.max_bytes, do: [max_bytes: ctx.max_bytes], else: []

    with {:ok, payment} <- step(Payment.decode(header, decode_opts), ctx.offer),
         {:ok, payment} <- step(Payment.match(payment, ctx.offer), ctx.offer),
         request = Facilitator.request(payment, ctx.offer),
         :ok <- verify(ctx, request, payment),
         auth_key = "auth:" <> payment.payment_id,
         :ok <- claim_auth(ctx, auth_key, payment),
         {:ok, settlement} <- settle_and_record(ctx, request, payment, auth_key) do
      Logger.info(log("paid", payment.payer, settlement.transaction))

      {:ok,
       Plug.Conn.put_resp_header(conn, @response_header, Settlement.response_header(settlement)),
       settlement}
    end
  end

  defp step({:ok, _} = ok, _offer), do: ok
  defp step({:error, reason}, offer), do: refuse(offer, reason, nil)

  defp verify(%{facilitator: {module, config}} = ctx, request, payment) do
    case Safe.call(fn -> module.verify(request, config) end) do
      {:ok, {:ok, %{payer: payer}}} ->
        if is_nil(payer) or same_payer?(ctx.offer, payer, payment.payer) do
          :ok
        else
          Logger.error(log("verify_inconsistent", payment.payer, nil) <> " reason=payer_mismatch")
          {:error, :facilitator_unavailable}
        end

      {:ok, {:error, {:rejected, why}}} ->
        Logger.info(log("verification_failed", payment.payer, nil) <> " reason=#{code(why)}")
        refuse(ctx.offer, :verification_failed, :logged)

      {:ok, {:error, why}} ->
        unavailable("verify", short(why), payment)

      {:ok, _other} ->
        unavailable("verify", "unexpected_return", payment)

      {:caught, kind} ->
        unavailable("verify", "adapter_#{kind}", payment)
    end
  end

  defp claim_auth(%{guard: {module, config}} = ctx, key, payment) do
    meta = meta(ctx, :authorization, payment)

    case Safe.call(fn -> module.claim(key, meta, config) end) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, :replayed}} ->
        Logger.info(log("replayed", payment.payer, nil))
        refuse(ctx.offer, :replayed, :logged)

      _other ->
        Logger.error(log("replay_guard_unavailable", payment.payer, nil))
        {:error, :replay_guard_unavailable}
    end
  end

  # Settle, record and call on_settled in a process that outlives the
  # request, and wait for it.
  defp settle_and_record(ctx, request, payment, auth_key) do
    # The request's Logger metadata (request_id and the like) follows the work.
    metadata = Logger.metadata()

    task =
      Task.Supervisor.async_nolink(
        X402.TaskSupervisor,
        fn ->
          Logger.metadata(metadata)
          settle(ctx, request, payment, auth_key)
        end,
        shutdown: @settle_shutdown_ms
      )

    case Task.yield(task, ctx.await_ms) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        Logger.error(
          log("settle_crashed", payment.payer, nil) <> " reconcile=check_payer_on_chain"
        )

        {:error, :facilitator_unavailable}

      nil ->
        Process.demonitor(task.ref, [:flush])

        Logger.error(
          log("settle_still_running", payment.payer, nil) <> " reconcile=check_payer_on_chain"
        )

        {:error, :facilitator_unavailable}
    end
  end

  defp settle(%{facilitator: {module, config}} = ctx, request, payment, auth_key) do
    started = System.monotonic_time(:millisecond)

    case Safe.call(fn -> module.settle(request, config) end) do
      {:ok, {:ok, %Settlement{} = s}} ->
        case well_formed(ctx, s) do
          {:ok, s} ->
            accept(ctx, s, payment, auth_key)

          {:malformed, reason} ->
            # Whatever adapter this came from, nothing here can be keyed,
            # recorded or shown to the client; the money may still have moved.
            settle_unavailable(Atom.to_string(reason), payment)
        end

      {:ok, {:error, {:rejected, why}}} ->
        Logger.warning(log("settlement_failed", payment.payer, nil) <> " reason=#{code(why)}")
        refuse(ctx.offer, :settlement_failed, :logged)

      {:ok, {:error, {:pending, tx}}} ->
        retry_pending(ctx, request, payment, auth_key, tx, started)

      {:ok, {:error, why}} ->
        settle_unavailable(short(why), payment)

      {:ok, _other} ->
        settle_unavailable("unexpected_return", payment)

      {:caught, kind} ->
        settle_unavailable("adapter_#{kind}", payment)
    end
  end

  # A well-formed settlement: the report must agree with the signed payment,
  # then the money has moved and the record comes first.
  defp accept(ctx, s, payment, auth_key) do
    case consistent(ctx, s, payment) do
      :ok ->
        s = %{s | payer: payment.payer, payment_id: payment.payment_id}
        record(ctx, s, payment, auth_key)

      {:mismatch, reason} ->
        dispute(ctx, s, payment, auth_key, reason)
    end
  end

  # /settle answered settlement_pending with the hash it broadcast (spec 9,
  # non-terminal). Retry once, with the same request body, in this same task
  # and under the same "auth:" claim, as the reference server does
  # (settleWithPendingRetry). The chain spends an EIP-3009 nonce once, so a
  # second /settle cannot move the money twice, and the one claim means one
  # answer per authorization however the retry ends. The retry is given what
  # is left of the first call's settle budget, never less than
  # @retry_floor_ms, so settle, retry and the Stripe record fit
  # :settle_await_ms. Only a success naming the pending hash is accepted: a
  # different hash is the one answer that could book the wrong transaction,
  # so it is written as a disputed row keyed on the pending hash and served
  # nothing. A pending answer with no well-formed hash is not retried.
  defp retry_pending(ctx, request, payment, auth_key, pending, started) do
    {:ok, scheme} = Scheme.for(ctx.offer.scheme, ctx.offer.network)

    if scheme.valid_transaction?(pending) do
      retry_pending(ctx, request, payment, auth_key, String.downcase(pending), started, :retry)
    else
      Logger.error(log("settlement_pending", payment.payer, nil) <> " reconcile=on_chain")
      refuse(ctx.offer, :settlement_pending, :logged)
    end
  end

  defp retry_pending(
         %{facilitator: {module, config}} = ctx,
         request,
         payment,
         auth_key,
         pending,
         started,
         :retry
       ) do
    retry_config = retry_config(config, started)

    case Safe.call(fn -> module.settle(request, retry_config) end) do
      {:ok, {:ok, %Settlement{} = s}} ->
        case well_formed(ctx, s) do
          {:ok, %Settlement{transaction: ^pending} = s} ->
            accept(ctx, s, payment, auth_key)

          {:ok, %Settlement{transaction: other} = s} ->
            Logger.error(
              log("pending_hash_changed", payment.payer, pending) <>
                " retry_tx_hash=#{other} reconcile=on_chain"
            )

            dispute(ctx, %{s | transaction: pending}, payment, auth_key, :pending_hash_changed)

          {:malformed, reason} ->
            retry_unavailable(Atom.to_string(reason), payment, pending)
        end

      {:ok, {:error, {:pending, again}}} ->
        Logger.error(
          log("settlement_pending", payment.payer, pending) <>
            " retry=pending retry_tx_hash=#{code(again)} reconcile=on_chain"
        )

        refuse(ctx.offer, :settlement_pending, :logged)

      {:ok, {:error, {:rejected, why}}} ->
        # The first call broadcast a transaction; a refusal now does not undo it.
        Logger.error(
          log("settlement_pending", payment.payer, pending) <>
            " retry=rejected reason=#{code(why)} reconcile=on_chain"
        )

        refuse(ctx.offer, :settlement_pending, :logged)

      {:ok, {:error, why}} ->
        retry_unavailable(short(why), payment, pending)

      {:ok, _other} ->
        retry_unavailable("unexpected_return", payment, pending)

      {:caught, kind} ->
        retry_unavailable("adapter_#{kind}", payment, pending)
    end
  end

  # What is left of the settle budget after the first call, floor @retry_floor_ms.
  defp retry_config(config, started) when is_list(config) do
    budget = Keyword.get(config, :settle_timeout, Facilitator.HTTP.default_settle_timeout())
    elapsed = System.monotonic_time(:millisecond) - started
    Keyword.put(config, :settle_timeout, max(budget - elapsed, @retry_floor_ms))
  end

  defp retry_config(config, _started), do: config

  defp retry_unavailable(reason, payment, pending) do
    Logger.error(
      log("settle_retry_unavailable", payment.payer, pending) <>
        " reason=#{reason} reconcile=on_chain"
    )

    {:error, :facilitator_unavailable}
  end

  # A settlement is checked here whichever adapter returned it: the hash must
  # be well formed for the offer's scheme and the network the offer's, and
  # the hash is lowercased once, so the "tx:" key, the row, Stripe's
  # idempotency key and PAYMENT-RESPONSE all carry the same form.
  defp well_formed(ctx, %Settlement{} = s) do
    {:ok, scheme} = Scheme.for(ctx.offer.scheme, ctx.offer.network)

    cond do
      not scheme.valid_transaction?(s.transaction) -> {:malformed, :invalid_transaction}
      s.network != ctx.offer.network -> {:malformed, :settlement_network_mismatch}
      true -> {:ok, %{s | transaction: String.downcase(s.transaction)}}
    end
  end

  defp tx_key(%Settlement{} = s), do: "tx:" <> s.network <> ":" <> s.transaction

  # The facilitator's report must agree with what the client signed.
  defp consistent(ctx, s, payment) do
    cond do
      s.amount != nil and s.amount != ctx.offer.amount ->
        {:mismatch, :amount_mismatch}

      s.payer != nil and not same_payer?(ctx.offer, s.payer, payment.payer) ->
        {:mismatch, :payer_mismatch}

      true ->
        :ok
    end
  end

  # /settle said success, but its report contradicts the signed payment. The
  # money may have moved, so write a flagged "tx:" row for ops and the
  # reconciler to see (it is not booked to Stripe: we don't believe its
  # amount), and serve nothing.
  defp dispute(%{guard: {module, config}} = ctx, s, payment, auth_key, reason) do
    meta =
      ctx
      |> meta(:transaction_disputed, payment)
      |> Map.merge(%{tx_hash: s.transaction, auth_key: auth_key, dispute: reason})

    written =
      case Safe.call(fn -> module.claim(tx_key(s), meta, config) end) do
        {:ok, :ok} -> "true"
        _ -> "false"
      end

    Logger.error(
      log("settle_inconsistent", payment.payer, s.transaction) <>
        " reason=#{reason} disputed_row=#{written} reconcile=on_chain"
    )

    {:error, :facilitator_unavailable}
  end

  defp same_payer?(offer, a, b) do
    {:ok, scheme} = Scheme.for(offer.scheme, offer.network)
    scheme.same_address?(a, b)
  end

  # The money has moved. First the durable record, then on_settled.
  defp record(%{guard: {module, config}} = ctx, s, payment, auth_key) do
    tx_key = tx_key(s)

    meta =
      ctx
      |> meta(:transaction, payment)
      |> Map.merge(%{tx_hash: s.transaction, auth_key: auth_key})

    case Safe.call(fn -> module.claim(tx_key, meta, config) end) do
      {:ok, :ok} ->
        settled(ctx, s, payment, tx_key)
        {:ok, s}

      {:ok, {:error, :replayed}} ->
        # The facilitator reported a transaction already claimed for another
        # authorization: not a payment for this one.
        Logger.error(log("transaction_already_claimed", payment.payer, s.transaction))
        refuse(ctx.offer, :replayed, :logged)

      _guard_error ->
        Logger.error(log("tx_claim_failed", payment.payer, s.transaction) <> " served=true")
        settled(ctx, s, payment, nil)
        {:ok, s}
    end
  end

  defp settled(%{on_settled: nil}, _s, _payment, _tx_key), do: :ok

  defp settled(%{on_settled: fun} = ctx, s, payment, tx_key) do
    case Safe.call(fn -> fun.(%{settlement: s, offer: ctx.offer, payer: payment.payer}) end) do
      {:ok, {:ok, "pi_" <> _ = id}} when is_binary(tx_key) ->
        store_payment_intent(ctx, tx_key, id, s, payment)

      {:ok, {:error, why}} ->
        Logger.error(
          log("on_settled_failed", payment.payer, s.transaction) <> " reason=#{short(why)}"
        )

      {:caught, kind} ->
        Logger.error(log("on_settled_crashed", payment.payer, s.transaction) <> " kind=#{kind}")

      _ ->
        :ok
    end
  end

  defp store_payment_intent(%{guard: {module, config}}, tx_key, id, s, payment) do
    case Safe.call(fn -> module.record_payment_intent(tx_key, id, config) end) do
      {:ok, :ok} ->
        :ok

      _ ->
        Logger.error(
          log("payment_intent_not_stored", payment.payer, s.transaction) <>
            " payment_intent=#{code(id)}"
        )
    end
  end

  defp meta(ctx, kind, payment) do
    %{
      kind: kind,
      app: ctx.app,
      network: ctx.offer.network,
      asset: ctx.offer.asset,
      pay_to: ctx.offer.pay_to,
      payer: payment.payer,
      amount: ctx.offer.amount,
      resource: ctx.offer.resource,
      tx_hash: nil,
      auth_key: nil,
      dispute: nil
    }
  end

  defp unavailable(op, reason, payment) do
    Logger.error(log("#{op}_unavailable", payment.payer, nil) <> " reason=#{reason}")
    {:error, :facilitator_unavailable}
  end

  defp settle_unavailable(reason, payment) do
    Logger.error(
      log("settle_unavailable", payment.payer, nil) <>
        " reason=#{reason} reconcile=check_payer_on_chain"
    )

    {:error, :facilitator_unavailable}
  end

  defp refuse(offer, reason, payer) do
    if payer != :logged do
      level = if reason in @decode_reasons, do: :debug, else: :info
      Logger.log(level, log(Atom.to_string(reason), payer, nil))
    end

    {:payment_required, Offer.challenge_header(offer, Atom.to_string(reason)), reason}
  end

  defp log(outcome, payer, tx_hash) do
    "x402 outcome=#{outcome} payer=#{payer || "-"} tx_hash=#{tx_hash || "-"}"
  end

  defp short(why), do: Safe.reason(why)

  # A facilitator adapter's reason or hash, printed only if it is a plain token.
  defp code(s) when is_binary(s),
    do: if(s =~ ~r/\A[A-Za-z0-9_]{1,128}\z/, do: s, else: "unknown")

  defp code(_), do: "unknown"
end
