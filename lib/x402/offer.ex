defmodule X402.Offer do
  @moduledoc """
  What a resource costs, and the `PAYMENT-REQUIRED` challenge that says so.

  An offer is plain data: the scheme, the network (CAIP-2), the asset, the
  amount in the asset's atomic units, who is paid and for which resource.
  Nothing here is specific to one chain; `X402.Scheme.for/2` picks the module
  that knows the rules for a scheme on a network, and `new/1` asks it to check
  the offer. Adding a network means adding a scheme module, not changing this API.

      {:ok, offer} =
        X402.Offer.new(%{
          amount: 10_000,
          network: "eip155:84532",
          asset: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
          extra: %{"name" => "USDC", "version" => "2"},
          pay_to: "0x209693Bc6afc0C5328bA36FaF03C514EF312287C",
          resource: "https://example.org/data",
          description: "One page over the crawl budget",
          max_timeout_seconds: 60
        })

      X402.Offer.challenge_header(offer)
      #=> "eyJ4NDAyVmVyc2lvbiI6Mi..."

  Field names on the wire follow the x402 v2 spec, section 5.1
  (docs/SPEC_NOTES.md, "PaymentRequired").
  """

  alias X402.{Codec, Scheme}

  @x402_version 2

  @enforce_keys [:scheme, :network, :amount, :asset, :pay_to, :resource, :max_timeout_seconds]
  defstruct [
    :scheme,
    :network,
    :amount,
    :asset,
    :pay_to,
    :resource,
    :description,
    :mime_type,
    :max_timeout_seconds,
    extra: %{}
  ]

  @type t :: %__MODULE__{
          scheme: String.t(),
          network: String.t(),
          amount: String.t(),
          asset: String.t(),
          pay_to: String.t(),
          resource: String.t(),
          description: String.t() | nil,
          mime_type: String.t() | nil,
          max_timeout_seconds: pos_integer(),
          extra: %{optional(String.t()) => term()}
        }

  @doc "The protocol version this library speaks."
  def x402_version, do: @x402_version

  @doc """
  Builds and checks an offer.

  Takes a map (atom keys) with `:amount`, `:asset`, `:network`, `:pay_to`,
  `:resource`, `:max_timeout_seconds`, and optionally `:description`,
  `:mime_type`, `:extra` (string keys) and `:scheme` (default `"exact"`).

  `:amount` is a positive integer or a string of decimal digits, in the
  asset's atomic units (USDC has 6 decimals: 10_000 is $0.01).
  """
  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    with {:ok, amount} <- amount(Map.get(attrs, :amount)),
         {:ok, scheme} <- string(attrs, :scheme, "exact"),
         {:ok, network} <- string(attrs, :network),
         {:ok, asset} <- string(attrs, :asset),
         {:ok, pay_to} <- string(attrs, :pay_to),
         {:ok, resource} <- resource(Map.get(attrs, :resource)),
         {:ok, timeout} <- timeout(Map.get(attrs, :max_timeout_seconds)),
         {:ok, description} <- optional_string(attrs, :description),
         {:ok, mime_type} <- optional_string(attrs, :mime_type),
         {:ok, extra} <- extra(Map.get(attrs, :extra, %{})) do
      offer = %__MODULE__{
        scheme: scheme,
        network: network,
        amount: amount,
        asset: asset,
        pay_to: pay_to,
        resource: resource,
        description: description,
        mime_type: mime_type,
        max_timeout_seconds: timeout,
        extra: extra
      }

      with {:ok, module} <- Scheme.for(scheme, network),
           :ok <- module.validate_offer(offer) do
        {:ok, offer}
      end
    end
  end

  def new(_), do: {:error, :invalid_offer}

  @doc "Like `new/1`, raising `ArgumentError` on an invalid offer."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, offer} -> offer
      {:error, reason} -> raise ArgumentError, "invalid x402 offer: #{inspect(reason)}"
    end
  end

  @doc "The `PaymentRequirements` object (one entry of `accepts`), JSON-shaped."
  @spec requirements(t()) :: map()
  def requirements(%__MODULE__{} = offer) do
    %{
      "scheme" => offer.scheme,
      "network" => offer.network,
      "amount" => offer.amount,
      "asset" => offer.asset,
      "payTo" => offer.pay_to,
      "maxTimeoutSeconds" => offer.max_timeout_seconds,
      "extra" => offer.extra
    }
  end

  @doc "The `ResourceInfo` object, JSON-shaped."
  @spec resource_info(t()) :: map()
  def resource_info(%__MODULE__{} = offer) do
    %{"url" => offer.resource}
    |> put_present("description", offer.description)
    |> put_present("mimeType", offer.mime_type)
  end

  @doc "The `PaymentRequired` object, JSON-shaped, with an optional human-readable `error`."
  @spec payment_required(t(), String.t() | nil) :: map()
  def payment_required(%__MODULE__{} = offer, error \\ nil) do
    %{
      "x402Version" => @x402_version,
      "resource" => resource_info(offer),
      "accepts" => [requirements(offer)]
    }
    |> put_present("error", error)
  end

  @doc "The value of the `PAYMENT-REQUIRED` header: base64 JSON of `payment_required/2`."
  @spec challenge_header(t(), String.t() | nil) :: String.t()
  def challenge_header(%__MODULE__{} = offer, error \\ nil) do
    offer |> payment_required(error) |> Codec.encode()
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp amount(n) when is_integer(n) and n > 0, do: {:ok, Integer.to_string(n)}

  defp amount(s) when is_binary(s) do
    if s =~ ~r/\A[1-9][0-9]{0,77}\z/, do: {:ok, s}, else: {:error, :invalid_amount}
  end

  defp amount(_), do: {:error, :invalid_amount}

  defp string(attrs, key, default \\ nil) do
    case Map.get(attrs, key, default) do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, :"invalid_#{key}"}
    end
  end

  defp optional_string(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      s when is_binary(s) -> {:ok, s}
      _ -> {:error, :"invalid_#{key}"}
    end
  end

  defp resource(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, :invalid_resource}
    end
  end

  defp resource(_), do: {:error, :invalid_resource}

  defp timeout(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp timeout(_), do: {:error, :invalid_max_timeout_seconds}

  defp extra(map) when is_map(map) do
    if Enum.all?(Map.keys(map), &is_binary/1), do: {:ok, map}, else: {:error, :invalid_extra}
  end

  defp extra(_), do: {:error, :invalid_extra}
end
