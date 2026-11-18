defmodule X402.HTTPClient do
  @moduledoc """
  The one place this library makes an HTTP request (facilitators and Stripe).

  Every request:

    * sends no retries and follows no redirects;
    * asks for no compression and decodes none (`compressed: false`,
      `decode_body: false`), so a small body cannot expand;
    * caps the response body at `:max_body_bytes` (default 64 KB), stopping
      the read when it is passed (`{:error, :too_large}`);
    * bounds the whole response by `:deadline_ms`, checked on every chunk,
      because Finch's `receive_timeout` applies to each chunk, not the response.
      A body that trickles in stops at the deadline plus one `receive_timeout`.

  `:req_options` is a test seam (`plug: {Req.Test, name}`). It can point the
  request at a local plug, which would forge a facilitator's verdict, so it is
  refused (`{:error, :req_options_not_allowed}`) unless the application sets
  `config :x402_ex, allow_req_options: true`, which belongs in `config/test.exs` only.
  """

  require Logger

  @default_max_body 65_536

  @type error :: :timeout | :too_large | :unavailable | :req_options_not_allowed

  @doc false
  @spec request(keyword(), keyword()) ::
          {:ok, non_neg_integer(), binary()} | {:error, error()}
  def request(req_opts, opts) do
    max = Keyword.get(opts, :max_body_bytes, @default_max_body)
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :deadline_ms)

    with {:ok, extra} <- req_options(Keyword.get(opts, :req_options, [])) do
      req =
        req_opts
        |> Keyword.merge(
          retry: false,
          redirect: false,
          compressed: false,
          decode_body: false,
          into: collector(max, deadline)
        )
        |> Req.new()
        |> Req.merge(extra)

      run(req)
    end
  end

  defp run(req) do
    case Req.request(req) do
      {:ok, %Req.Response{private: %{x402_abort: reason}}} ->
        {:error, reason}

      {:ok, %Req.Response{status: status} = resp} ->
        {:ok, status, IO.iodata_to_binary(resp.private[:x402_body] || [])}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %{__struct__: mod} = e} ->
        Logger.warning("x402 http request failed: #{reason_name(e, mod)}")
        {:error, :unavailable}
    end
  end

  defp collector(max, deadline) do
    fn {:data, data}, {req, resp} ->
      body = [resp.private[:x402_body] || [] | [data]]
      size = (resp.private[:x402_size] || 0) + byte_size(data)

      cond do
        size > max ->
          {:halt, {req, Req.Response.put_private(resp, :x402_abort, :too_large)}}

        System.monotonic_time(:millisecond) > deadline ->
          {:halt, {req, Req.Response.put_private(resp, :x402_abort, :timeout)}}

        true ->
          resp =
            resp
            |> Req.Response.put_private(:x402_body, body)
            |> Req.Response.put_private(:x402_size, size)

          {:cont, {req, resp}}
      end
    end
  end

  defp req_options([]), do: {:ok, []}

  defp req_options(opts) when is_list(opts) do
    if Application.get_env(:x402_ex, :allow_req_options, false) do
      {:ok, opts}
    else
      Logger.error(
        "x402 :req_options given but not allowed; set allow_req_options in test config only"
      )

      {:error, :req_options_not_allowed}
    end
  end

  defp req_options(_), do: {:error, :req_options_not_allowed}

  defp reason_name(%Req.TransportError{reason: reason}, _) when is_atom(reason),
    do: inspect(reason)

  defp reason_name(_, mod), do: inspect(mod)
end
