defmodule X402.Facilitator.X402Org do
  @moduledoc """
  The public test facilitator at `https://x402.org/facilitator`, for the
  Base Sepolia sandbox (`eip155:84532`). No credentials.

  The URL is the reference client's `DEFAULT_FACILITATOR_URL`, and Stripe's
  x402 guide names it for sandbox testing (docs/SPEC_NOTES.md, "Facilitators").

  Config: `:url` overrides the default; every other key is passed to
  `X402.Facilitator.HTTP` (timeouts, `:req_options`).

      facilitator: {X402.Facilitator.X402Org, []}
  """

  @behaviour X402.Facilitator

  @default_url "https://x402.org/facilitator"

  @doc "The default facilitator URL."
  def default_url, do: @default_url

  @impl true
  def verify(request, config), do: X402.Facilitator.HTTP.verify(request, with_url(config))

  @impl true
  def settle(request, config), do: X402.Facilitator.HTTP.settle(request, with_url(config))

  defp with_url(config), do: Keyword.put_new(config, :url, @default_url)
end
