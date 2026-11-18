defmodule X402.OfferTest do
  use ExUnit.Case, async: true

  alias X402.{Codec, Fixtures, Offer}

  test "the challenge header round-trips to the spec's PaymentRequired shape" do
    offer = Fixtures.offer()
    header = Offer.challenge_header(offer, "PAYMENT-SIGNATURE header is required")

    assert {:ok, decoded} = Codec.decode(header)

    assert decoded == %{
             "x402Version" => 2,
             "error" => "PAYMENT-SIGNATURE header is required",
             "resource" => %{
               "url" => "https://example.org/data",
               "description" => "One page over the crawl budget"
             },
             "accepts" => [
               %{
                 "scheme" => "exact",
                 "network" => "eip155:84532",
                 "amount" => "10000",
                 "asset" => Fixtures.asset(),
                 "payTo" => Fixtures.pay_to(),
                 "maxTimeoutSeconds" => 60,
                 "extra" => %{"name" => "USDC", "version" => "2"}
               }
             ]
           }

    assert header =~ ~r/\A[A-Za-z0-9+\/]+=*\z/
  end

  test "the amount may be given as a digit string" do
    assert Fixtures.offer(%{amount: "250000"}).amount == "250000"
  end

  describe "refuses an invalid offer" do
    for {field, value, reason} <- [
          {:amount, 0, :invalid_amount},
          {:amount, -1, :invalid_amount},
          {:amount, "0010", :invalid_amount},
          {:amount, "1.5", :invalid_amount},
          {:network, "solana:x", :unsupported_scheme},
          {:network, "eip155:", :unsupported_scheme},
          {:scheme, "upto", :unsupported_scheme},
          {:asset, "0x123", :invalid_asset},
          {:pay_to, "not-an-address", :invalid_pay_to},
          {:resource, "/relative", :invalid_resource},
          {:resource, "ftp://example.org/x", :invalid_resource},
          {:max_timeout_seconds, 0, :invalid_max_timeout_seconds},
          {:extra, %{"name" => "USDC"}, :missing_extra_version},
          {:extra, %{"name" => "USDC", "version" => "2", "assetTransferMethod" => "permit2"},
           :unsupported_asset_transfer_method}
        ] do
      test "#{field} = #{inspect(value)}" do
        attrs = %{
          amount: 10_000,
          network: "eip155:84532",
          asset: Fixtures.asset(),
          extra: %{"name" => "USDC", "version" => "2"},
          pay_to: Fixtures.pay_to(),
          resource: Fixtures.resource(),
          max_timeout_seconds: 60
        }

        assert Offer.new(Map.put(attrs, unquote(field), unquote(Macro.escape(value)))) ==
                 {:error, unquote(reason)}
      end
    end
  end

  describe "on a network whose USDC is known" do
    test "refuses another token, or USDC from another network" do
      assert Offer.new(offer_attrs(%{asset: "0x" <> String.duplicate("2", 40)})) ==
               {:error, :unknown_asset_for_network}

      # Base mainnet's USDC on Base Sepolia: a copied config.
      assert Offer.new(offer_attrs(%{asset: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"})) ==
               {:error, :unknown_asset_for_network}
    end

    test "refuses the wrong EIP-712 domain" do
      {:ok, usdc} = X402.Scheme.ExactEvm.usdc("eip155:8453")

      # Base Sepolia's domain name ("USDC") on mainnet, where it is "USD Coin".
      attrs =
        offer_attrs(%{
          network: "eip155:8453",
          asset: usdc.asset,
          extra: %{"name" => "USDC", "version" => "2"}
        })

      assert Offer.new(attrs) == {:error, :wrong_asset_domain}
    end

    test "allows another token when the offer says so" do
      attrs = offer_attrs(%{asset: "0x" <> String.duplicate("2", 40), allow_unknown_asset: true})
      assert {:ok, %Offer{allow_unknown_asset: true}} = Offer.new(attrs)
    end

    test "allows any token on a network it does not know" do
      attrs = offer_attrs(%{network: "eip155:1", asset: "0x" <> String.duplicate("2", 40)})
      assert {:ok, _} = Offer.new(attrs)
    end
  end

  defp offer_attrs(overrides) do
    Map.merge(
      %{
        amount: 10_000,
        network: "eip155:84532",
        asset: Fixtures.asset(),
        extra: %{"name" => "USDC", "version" => "2"},
        pay_to: Fixtures.pay_to(),
        resource: Fixtures.resource(),
        max_timeout_seconds: 60
      },
      overrides
    )
  end

  test "USDC on Base and Base Sepolia" do
    assert {:ok, %{asset: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"}} =
             X402.Scheme.ExactEvm.usdc("eip155:8453")

    assert {:ok, %{asset: "0x036CbD53842c5426634e7929541eC2318f3dCF7e"}} =
             X402.Scheme.ExactEvm.usdc("eip155:84532")

    assert :error = X402.Scheme.ExactEvm.usdc("eip155:1")
  end
end
