defmodule X402.PaymentTest do
  use ExUnit.Case, async: true

  alias X402.{Fixtures, Payment}

  setup do
    offer = Fixtures.offer()
    %{offer: offer, payment: Fixtures.payment(offer)}
  end

  defp decode_and_match(map, offer) do
    with {:ok, payment} <- Payment.decode(Fixtures.header(map)) do
      Payment.match(payment, offer)
    end
  end

  describe "decode/2 refuses" do
    test "a header over 8 KB, before decoding it" do
      assert Payment.decode(String.duplicate("A", 8_193)) == {:error, :header_too_large}
    end

    test "a header over a smaller cap" do
      assert Payment.decode(String.duplicate("A", 101), max_bytes: 100) ==
               {:error, :header_too_large}
    end

    test "invalid base64" do
      assert Payment.decode("not base64!!") == {:error, :invalid_base64}
      assert Payment.decode("") == {:error, :invalid_json}
    end

    test "the URL-safe alphabet" do
      # "?>?" encodes to "Pz4/" in the standard alphabet, "Pz4_" in the URL-safe one.
      assert Payment.decode("Pz4_") == {:error, :invalid_base64}
    end

    test "invalid JSON" do
      assert Payment.decode(Base.encode64("{not json")) == {:error, :invalid_json}
      assert Payment.decode(Base.encode64(<<0xFF, 0xFE>>)) == {:error, :invalid_json}
    end

    test "JSON that is not an object" do
      assert Payment.decode(Base.encode64("[1,2]")) == {:error, :not_an_object}
      assert Payment.decode(Base.encode64("\"x\"")) == {:error, :not_an_object}
    end

    test "a version other than the integer 2", %{payment: p} do
      for v <- [1, 3, "2", 2.0, nil] do
        assert Payment.decode(Fixtures.header(Map.put(p, "x402Version", v))) ==
                 {:error, :unsupported_version}
      end
    end

    test "wrongly typed fields", %{payment: p} do
      bad = [
        put_in(p, ["accepted", "amount"], 10_000),
        put_in(p, ["accepted", "maxTimeoutSeconds"], "60"),
        put_in(p, ["accepted", "extra"], "USDC"),
        Map.put(p, "accepted", "exact"),
        Map.delete(p, "payload"),
        Map.put(p, "resource", %{"url" => 1})
      ]

      for map <- bad do
        assert Payment.decode(Fixtures.header(map)) == {:error, :invalid_payload}
      end
    end

    test "without creating atoms", %{payment: p} do
      key = "never_an_atom_#{System.unique_integer([:positive])}"
      {:ok, _} = Payment.decode(Fixtures.header(Map.put(p, key, %{key => key})))
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end
  end

  test "decodes unpadded base64", %{payment: p} do
    header = p |> Jason.encode!() |> Base.encode64(padding: false)
    assert {:ok, %Payment{}} = Payment.decode(header)
  end

  test "match/2 accepts the matching payment", %{payment: p, offer: offer} do
    assert {:ok, %Payment{payer: payer, payment_id: id}} = decode_and_match(p, offer)
    assert payer == Fixtures.payer()

    assert id ==
             "exact:eip155:84532:" <>
               String.downcase(Fixtures.asset()) <>
               ":" <> String.downcase(Fixtures.payer()) <> ":" <> Fixtures.nonce()
  end

  test "match/2 compares EVM addresses case-insensitively", %{payment: p, offer: offer} do
    p =
      p
      |> put_in(["accepted", "payTo"], String.downcase(Fixtures.pay_to()))
      |> put_in(
        ["accepted", "asset"],
        String.upcase(Fixtures.asset()) |> String.replace("0X", "0x")
      )
      |> put_in(["payload", "authorization", "to"], String.downcase(Fixtures.pay_to()))

    assert {:ok, _} = decode_and_match(p, offer)
  end

  test "match/2 lets the client add keys to extra", %{payment: p, offer: offer} do
    p = put_in(p, ["accepted", "extra", "assetTransferMethod"], "eip3009")
    assert {:ok, _} = decode_and_match(p, offer)
  end

  describe "match/2 refuses" do
    test "a wrong amount", %{payment: p, offer: offer} do
      assert decode_and_match(put_in(p, ["accepted", "amount"], "9999"), offer) ==
               {:error, :amount_mismatch}

      assert decode_and_match(put_in(p, ["accepted", "amount"], "010000"), offer) ==
               {:error, :amount_mismatch}
    end

    test "an authorization for a different value", %{payment: p, offer: offer} do
      p = put_in(p, ["payload", "authorization", "value"], "1")
      assert decode_and_match(p, offer) == {:error, :amount_mismatch}
    end

    test "a wrong pay_to", %{payment: p, offer: offer} do
      other = "0x" <> String.duplicate("1", 40)

      assert decode_and_match(put_in(p, ["accepted", "payTo"], other), offer) ==
               {:error, :pay_to_mismatch}

      assert decode_and_match(put_in(p, ["payload", "authorization", "to"], other), offer) ==
               {:error, :pay_to_mismatch}
    end

    test "a wrong network", %{payment: p, offer: offer} do
      assert decode_and_match(put_in(p, ["accepted", "network"], "eip155:8453"), offer) ==
               {:error, :network_mismatch}
    end

    test "a wrong asset", %{payment: p, offer: offer} do
      p = put_in(p, ["accepted", "asset"], "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")
      assert decode_and_match(p, offer) == {:error, :asset_mismatch}
    end

    test "a wrong scheme", %{payment: p, offer: offer} do
      assert decode_and_match(put_in(p, ["accepted", "scheme"], "upto"), offer) ==
               {:error, :scheme_mismatch}
    end

    test "a wrong resource", %{payment: p, offer: offer} do
      p = put_in(p, ["resource", "url"], "https://example.org/other")
      assert decode_and_match(p, offer) == {:error, :resource_mismatch}
    end

    test "a missing resource", %{payment: p, offer: offer} do
      assert decode_and_match(Map.delete(p, "resource"), offer) == {:error, :resource_mismatch}
    end

    test "a different maxTimeoutSeconds", %{payment: p, offer: offer} do
      p = put_in(p, ["accepted", "maxTimeoutSeconds"], 3600)
      assert decode_and_match(p, offer) == {:error, :max_timeout_mismatch}
    end

    test "a changed extra", %{payment: p, offer: offer} do
      p = put_in(p, ["accepted", "extra", "name"], "Not USDC")
      assert decode_and_match(p, offer) == {:error, :extra_mismatch}
    end

    test "a Permit2 transfer", %{payment: p, offer: offer} do
      p = put_in(p, ["accepted", "extra", "assetTransferMethod"], "permit2")
      assert decode_and_match(p, offer) == {:error, :unsupported_asset_transfer_method}
    end

    test "a malformed authorization", %{payment: p, offer: offer} do
      bad = [
        put_in(p, ["payload", "authorization", "from"], "0x12"),
        put_in(p, ["payload", "authorization", "nonce"], "0x01"),
        put_in(p, ["payload", "authorization", "validBefore"], 1_740_672_154),
        put_in(p, ["payload", "signature"], "0xabc"),
        put_in(p, ["payload"], %{"signature" => "0x" <> String.duplicate("ab", 65)})
      ]

      for map <- bad do
        assert decode_and_match(map, offer) == {:error, :invalid_payload}
      end
    end
  end
end
