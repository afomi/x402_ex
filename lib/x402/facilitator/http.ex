defmodule X402.Facilitator.HTTP do
  @moduledoc """
  The HTTP calls shared by facilitator adapters: `POST <url>/verify` and
  `POST <url>/settle` with a JSON body, parsed strictly.

  Mirrors the reference `HTTPFacilitatorClient` (typescript/packages/core/src/
  http/httpFacilitatorClient.ts), with these deliberate differences:

    * no retries, and redirects are not followed (a facilitator that moves
      should be reconfigured, not followed with payment data);
    * short timeouts: `:connect_timeout` (default 2,000 ms) and
      `:receive_timeout` (default 5,000 ms for verify, 15,000 ms for settle,
      which waits for a transaction receipt);
    * the response body is parsed by us with string keys, never as atoms.

  Config keys: `:url` (required), `:headers` (extra request headers, e.g.
  auth), `:connect_timeout`, `:verify_timeout`, `:settle_timeout`, and
  `:req_options` (merged into the Req request; tests pass `plug:` here).
  """

  require Logger

  alias X402.{Scheme, Settlement}

  @reason ~r/\A[a-z0-9_]{1,64}\z/

  @doc false
  def verify(request, config) do
    with {:ok, status, body} <- post(config, "/verify", request, :verify_timeout, 5_000) do
      parse_verify(status, body)
    end
  end

  @doc false
  def settle(request, config) do
    with {:ok, status, body} <- post(config, "/settle", request, :settle_timeout, 15_000) do
      parse_settle(status, body, request)
    end
  end

  defp post(config, path, request, timeout_key, default_timeout) do
    url = Keyword.fetch!(config, :url) |> String.trim_trailing("/")

    req =
      Req.new(
        method: :post,
        url: url <> path,
        json: request,
        headers: Keyword.get(config, :headers, []),
        retry: false,
        redirect: false,
        decode_body: false,
        connect_options: [timeout: Keyword.get(config, :connect_timeout, 2_000)],
        receive_timeout: Keyword.get(config, timeout_key, default_timeout)
      )
      |> Req.merge(Keyword.get(config, :req_options, []))

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, status, decode(body)}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, exception} ->
        Logger.warning("x402 facilitator #{path} unreachable: #{exception_name(exception)}")
        {:error, :unavailable}
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body, keys: :strings) do
      {:ok, map} when is_map(map) -> map
      _ -> :invalid
    end
  end

  defp decode(_), do: :invalid

  # 2xx with isValid true is the only success. A body that says isValid
  # false is a refusal whatever the status (as the reference client treats
  # it); any other non-2xx is an HTTP error.
  defp parse_verify(status, %{"isValid" => true} = body) when status in 200..299 do
    case body["payer"] do
      payer when is_binary(payer) or is_nil(payer) -> {:ok, %{payer: payer}}
      _ -> {:error, :invalid_response}
    end
  end

  defp parse_verify(_status, %{"isValid" => false} = body),
    do: {:error, {:rejected, reason(body["invalidReason"])}}

  defp parse_verify(status, _body) when status in 200..299, do: {:error, :invalid_response}
  defp parse_verify(status, _body), do: {:error, {:http_status, status}}

  defp parse_settle(status, %{"success" => true} = body, request) when status in 200..299 do
    network = get_in(request, ["paymentRequirements", "network"])
    scheme = get_in(request, ["paymentRequirements", "scheme"])
    tx = body["transaction"]
    payer = body["payer"]

    with {:ok, module} <- Scheme.for(scheme, network),
         true <- module.valid_transaction?(tx),
         true <- body["network"] == network,
         true <- is_nil(payer) or module.valid_address?(payer),
         true <- is_nil(body["amount"]) or uint?(body["amount"]) do
      {:ok, %Settlement{transaction: tx, network: network, payer: payer, amount: body["amount"]}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp parse_settle(
         _status,
         %{"success" => false, "errorReason" => "settlement_pending"} = body,
         request
       ) do
    case body["transaction"] do
      tx when is_binary(tx) and tx != "" ->
        if pending_tx_valid?(tx, request),
          do: {:error, {:pending, tx}},
          else: {:error, :invalid_response}

      _ ->
        {:error, {:rejected, "settlement_pending"}}
    end
  end

  defp parse_settle(_status, %{"success" => false} = body, _),
    do: {:error, {:rejected, reason(body["errorReason"])}}

  defp parse_settle(status, _body, _) when status in 200..299, do: {:error, :invalid_response}
  defp parse_settle(status, _body, _), do: {:error, {:http_status, status}}

  defp pending_tx_valid?(tx, request) do
    scheme = get_in(request, ["paymentRequirements", "scheme"])
    network = get_in(request, ["paymentRequirements", "network"])

    case Scheme.for(scheme, network) do
      {:ok, module} -> module.valid_transaction?(tx)
      _ -> false
    end
  end

  defp uint?(s) when is_binary(s), do: s =~ ~r/\A(?:0|[1-9][0-9]{0,77})\z/
  defp uint?(_), do: false

  defp reason(r) when is_binary(r), do: if(r =~ @reason, do: r, else: "unknown")
  defp reason(_), do: "unknown"

  defp exception_name(%{__struct__: mod} = e) do
    case e do
      %Req.TransportError{reason: reason} when is_atom(reason) -> inspect(reason)
      _ -> inspect(mod)
    end
  end
end
