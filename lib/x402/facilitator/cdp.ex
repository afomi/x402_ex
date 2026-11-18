defmodule X402.Facilitator.CDP do
  @moduledoc """
  The Coinbase Developer Platform facilitator, for Base mainnet (`eip155:8453`).

  URL: `https://api.cdp.coinbase.com/platform/v2/x402`, with `/verify` and
  `/settle` beneath it (x402 `go/legacy/pkg/coinbasefacilitator`, and the
  Stripe machine-payments sample's `CDP_FACILITATOR_URL`).

  ## Auth: NOT IMPLEMENTED in v0.1

  CDP authenticates each request with `Authorization: Bearer <JWT>`, a JWT
  signed with the API key secret and bound to one request
  (`POST api.cdp.coinbase.com/platform/v2/x402/verify`). The reference code
  builds it with the CDP SDK (`auth.GenerateJWT` in Go, `get_auth_headers`
  in Python); we have not reproduced its claims and key formats here.

  So with only `:key_id` and `:key_secret`, `verify/2` and `settle/2` return
  `{:error, :not_implemented}` and `X402.handle/2` fails closed. No request is sent.

  Pass the secret as a 0-arity function (`key_secret: fn -> System.fetch_env!("CDP_API_KEY_SECRET") end`),
  so it never sits in a keyword list that a crash report could print.
  A bare string is refused with `{:error, :invalid_config}`.

  The URL is fixed: a `:url` in config is ignored, so the bearer JWT can only
  go to `api.cdp.coinbase.com`.

  An app that can mint the JWT itself may pass
  `:auth_headers`, a function `(method, host, path) -> {:ok, headers} | {:error, term}`,
  and the calls go through. That path is tested against stubs only.

      facilitator: {X402.Facilitator.CDP, key_id: id, key_secret: fn -> secret() end}
  """

  @behaviour X402.Facilitator

  @host "api.cdp.coinbase.com"
  @base_path "/platform/v2/x402"

  @doc "The CDP facilitator URL."
  def url, do: "https://" <> @host <> @base_path

  @impl true
  def verify(request, config), do: call(:verify, request, config)

  @impl true
  def settle(request, config), do: call(:settle, request, config)

  defp call(op, request, config) do
    if is_binary(Keyword.get(config, :key_secret)),
      do: {:error, :invalid_config},
      else: call_with_auth(op, request, config)
  end

  defp call_with_auth(op, request, config) do
    case Keyword.get(config, :auth_headers) do
      fun when is_function(fun, 3) ->
        with {:ok, headers} <- auth(fun, "#{@base_path}/#{op}") do
          http_config =
            config
            |> Keyword.drop([:key_id, :key_secret, :auth_headers])
            |> Keyword.put(:url, url())
            |> Keyword.put(:headers, headers)

          apply(X402.Facilitator.HTTP, op, [request, http_config])
        end

      _ ->
        {:error, :not_implemented}
    end
  end

  defp auth(fun, path) do
    case fun.("POST", @host, path) do
      {:ok, headers} when is_list(headers) or is_map(headers) -> {:ok, headers}
      _ -> {:error, :unavailable}
    end
  end
end
