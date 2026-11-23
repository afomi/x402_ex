defmodule X402.Facilitator.CDP do
  @moduledoc """
  The Coinbase Developer Platform facilitator, for Base mainnet (`eip155:8453`).

  URL: `https://api.cdp.coinbase.com/platform/v2/x402`, with `/verify` and
  `/settle` beneath it (x402 `go/legacy/pkg/coinbasefacilitator/facilitator.go`,
  and CDP's API reference for "Verify a payment" and "Settle a payment").

  ## Auth

  Every call carries `Authorization: Bearer <JWT>`, a new JWT for each
  request, signed with the CDP API key and bound to that one request by its
  `uris` claim, `"POST api.cdp.coinbase.com/platform/v2/x402/verify"` (or
  `/settle`). It lasts 120 seconds. `X402.Facilitator.CDP.JWT` builds it the
  way CDP's SDK does, and documents the claims and key formats.

  Create a Secret API Key in the CDP portal (Ed25519, the default, or ECDSA),
  and pass its id and secret as 0-arity functions:

      facilitator:
        {X402.Facilitator.CDP,
         key_id: fn -> System.fetch_env!("CDP_API_KEY_ID") end,
         key_secret: fn -> System.fetch_env!("CDP_API_KEY_SECRET") end}

  `:key_id` may also be a plain string; it is not a secret (it is sent in
  every token), though it names your CDP account. `:key_secret` must be a
  function, so the secret never sits in a keyword list that a crash report
  could print; a bare string is refused with `{:error, :invalid_config}`.
  Both are read on every call, so a rotated key takes effect at once.

  The URL is fixed: a `:url` in config is ignored, so the bearer JWT can only
  go to `api.cdp.coinbase.com`, and the host and path it is bound to are the
  ones the request goes to.

  Other config: `:clock`, a 0-arity function returning Unix seconds (default
  `System.os_time(:second)`), for tests; and the `X402.Facilitator.HTTP` keys
  (timeouts, `:req_options`).

  Errors, all before any request is sent:

    * `{:error, :invalid_config}`: no key id or secret, a secret given as a
      string, a secret function that raises or returns something other than a
      non-empty string, a key in neither CDP format, or both a key and
      `:auth_headers`. A warning names the reason (an atom), never the key.
    * `{:error, :unavailable}`: the token could not be signed, or an
      `:auth_headers` function failed.

  ## Your own token

  An app that mints the JWT itself may instead pass `:auth_headers`, a
  function `(method, host, path) -> {:ok, headers} | {:error, term}`, and no
  key. It is called once per request.
  """

  @behaviour X402.Facilitator

  require Logger

  alias X402.Facilitator.CDP.JWT

  @host "api.cdp.coinbase.com"
  @base_path "/platform/v2/x402"
  @own_keys [:key_id, :key_secret, :auth_headers, :clock]

  @doc "The CDP facilitator URL."
  def url, do: "https://" <> @host <> @base_path

  @doc "The host every token is bound to."
  def host, do: @host

  @doc "The path a token for `:verify` or `:settle` is bound to."
  def path(op) when op in [:verify, :settle], do: "#{@base_path}/#{op}"

  @impl true
  def verify(request, config), do: call(:verify, request, config)

  @impl true
  def settle(request, config), do: call(:settle, request, config)

  defp call(op, request, config) do
    with {:ok, headers} <- headers(op, config) do
      http_config =
        config
        |> Keyword.drop(@own_keys)
        |> Keyword.put(:url, url())
        |> Keyword.put(:headers, headers)

      apply(X402.Facilitator.HTTP, op, [request, http_config])
    end
  end

  defp headers(op, config) do
    key_secret = Keyword.get(config, :key_secret)
    auth_headers = Keyword.get(config, :auth_headers)

    cond do
      is_binary(key_secret) ->
        refuse(:key_secret_not_a_function)

      key_secret != nil and auth_headers != nil ->
        refuse(:both_key_and_auth_headers)

      is_function(key_secret, 0) ->
        jwt_headers(op, config, key_secret)

      is_function(auth_headers, 3) ->
        own_headers(auth_headers, path(op))

      true ->
        refuse(:no_credentials)
    end
  end

  defp jwt_headers(op, config, key_secret) do
    with {:ok, key_id} <- read(Keyword.get(config, :key_id), :key_id),
         {:ok, secret} <- read(key_secret, :key_secret),
         {:ok, now} <- now(config),
         {:ok, key} <- parse(key_id, secret) do
      case JWT.sign(key, "POST", @host, path(op), now: now) do
        {:ok, token} ->
          {:ok, [{"authorization", "Bearer " <> token}]}

        {:error, why} ->
          Logger.warning("x402 CDP token not signed: #{why}")
          {:error, :unavailable}
      end
    end
  end

  # Only the outcome of the caller's function is kept: a raise could carry
  # the secret in its message, so its reason is dropped.
  defp read(value, :key_id) when is_binary(value) and value != "", do: {:ok, value}

  defp read(fun, name) when is_function(fun, 0) do
    case X402.Safe.call(fun) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> refuse(:"#{name}_unreadable")
    end
  end

  defp read(_, name), do: refuse(:"missing_#{name}")

  defp now(config) do
    case Keyword.get(config, :clock) do
      nil ->
        {:ok, System.os_time(:second)}

      fun when is_function(fun, 0) ->
        case X402.Safe.call(fun) do
          {:ok, n} when is_integer(n) and n > 0 -> {:ok, n}
          _ -> refuse(:clock_unreadable)
        end

      _ ->
        refuse(:clock_unreadable)
    end
  end

  defp parse(key_id, secret) do
    case JWT.parse_key(key_id, secret) do
      {:ok, key} -> {:ok, key}
      {:error, why} -> refuse(why)
    end
  end

  defp refuse(why) do
    Logger.warning("x402 CDP facilitator not configured: #{why}")
    {:error, :invalid_config}
  end

  defp own_headers(fun, path) do
    case X402.Safe.call(fn -> fun.("POST", @host, path) end) do
      {:ok, {:ok, headers}} when is_list(headers) or is_map(headers) -> {:ok, headers}
      _ -> {:error, :unavailable}
    end
  end
end
