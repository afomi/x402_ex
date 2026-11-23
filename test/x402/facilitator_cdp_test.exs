defmodule X402.FacilitatorCDPTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias X402.{Facilitator, Fixtures, Payment}
  alias X402.Facilitator.CDP
  alias X402.Facilitator.CDP.JWT

  # Published test keys only; everything else is generated per run.
  #
  # RFC 8037 appendix A.1: an Ed25519 key, as a JWK (d is the seed, x the public key).
  @rfc8037_d "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A"
  @rfc8037_x "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
  # RFC 8037 appendix A.4: that key signing "Example of Ed25519 signing".
  @rfc8037_input "eyJhbGciOiJFZERTQSJ9.RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc"
  @rfc8037_sig "hgyY0il_MGCjP0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g7sVvpAr_MuM0KAg"

  # RFC 7515 appendix A.3: an ES256 key and a JWS it signed.
  @rfc7515_x "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU"
  @rfc7515_y "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"
  @rfc7515_d "jpsQnnGQmL-YBIffH1136cspYG6-0iY7X1fCE9-E9LI"
  @rfc7515_jws "eyJhbGciOiJFUzI1NiJ9" <>
                 ".eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ" <>
                 ".DtEhU3ljbEg8L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q"

  @p256 {1, 2, 840, 10045, 3, 1, 7}
  @key_id "organizations/00000000-0000-4000-8000-000000000000/apiKeys/00000000-0000-4000-8000-000000000001"
  @now 1_800_000_000
  @nonce "0123456789abcdef0123456789abcdef"

  ## Keys

  defp d64(s), do: Base.url_decode64!(s, padding: false)

  # CDP's Ed25519 secret: base64 of seed || public key.
  defp ed25519_secret(seed, public), do: Base.encode64(seed <> public)

  defp new_ed25519 do
    {public, seed} = :crypto.generate_key(:eddsa, :ed25519)
    {ed25519_secret(seed, public), public}
  end

  defp ec_pem(private, public, type) do
    record = {:ECPrivateKey, 1, private, {:namedCurve, @p256}, public, :asn1_NOVALUE}
    :public_key.pem_encode([:public_key.pem_entry_encode(type, record)])
  end

  defp new_ec(type \\ :ECPrivateKey) do
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)
    {ec_pem(private, public, type), public}
  end

  ## Reading a token, independently of the signer

  defp parts(token) do
    [h, c, s] = String.split(token, ".")
    {h <> "." <> c, Jason.decode!(d64(h)), Jason.decode!(d64(c)), d64(s), d64(h), d64(c)}
  end

  # Checks the signature only; the claims are not parsed.
  defp valid?(token, public) do
    [h, c, s] = String.split(token, ".")
    input = h <> "." <> c
    sig = d64(s)
    header = Jason.decode!(d64(h))

    case header["alg"] do
      "EdDSA" ->
        :crypto.verify(:eddsa, :none, input, sig, [public, :ed25519])

      "ES256" ->
        <<r::unsigned-big-256, s::unsigned-big-256>> = sig
        der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
        :crypto.verify(:ecdsa, :sha256, input, der, [public, :secp256r1])
    end
  end

  defp bearer!(["Bearer " <> token]), do: token

  ## Published vectors: the primitives

  test "Ed25519 signs RFC 8037 A.4 exactly, from a CDP-format secret of its key" do
    secret = ed25519_secret(d64(@rfc8037_d), d64(@rfc8037_x))
    {:ok, key} = JWT.parse_key(@key_id, secret)

    assert key.alg == "EdDSA"
    assert Base.url_encode64(JWT.sign_input(key, @rfc8037_input), padding: false) == @rfc8037_sig
  end

  test "the JWS r || s reading checks RFC 7515 A.3's ES256 signature" do
    public = <<4>> <> d64(@rfc7515_x) <> d64(@rfc7515_y)
    assert valid?(@rfc7515_jws, public)

    tampered = String.replace(@rfc7515_jws, ".eyJpc3MiOiJqb2Ui", ".eyJpc3MiOiJqb2Uj")
    refute valid?(tampered, public)
  end

  ## The token's shape against a fixed key and clock

  test "the Ed25519 token, byte for byte, with a fixed key, clock and nonce" do
    secret = ed25519_secret(d64(@rfc8037_d), d64(@rfc8037_x))
    {:ok, key} = JWT.parse_key(@key_id, secret)

    {:ok, token} =
      JWT.sign(key, "POST", "api.cdp.coinbase.com", "/platform/v2/x402/verify",
        now: @now,
        nonce: @nonce
      )

    {_input, _header, _claims, sig, header_json, claims_json} = parts(token)

    assert header_json ==
             ~s({"alg":"EdDSA","kid":"#{@key_id}","nonce":"#{@nonce}","typ":"JWT"})

    assert claims_json ==
             ~s({"exp":1800000120,"iat":1800000000,"iss":"cdp","nbf":1800000000,) <>
               ~s("sub":"#{@key_id}","uris":["POST api.cdp.coinbase.com/platform/v2/x402/verify"]})

    assert byte_size(sig) == 64
    assert valid?(token, d64(@rfc8037_x))

    # Ed25519 is deterministic: the same inputs give the same token.
    assert {:ok, ^token} =
             JWT.sign(key, "POST", "api.cdp.coinbase.com", "/platform/v2/x402/verify",
               now: @now,
               nonce: @nonce
             )
  end

  test "the ES256 token with RFC 7515's key, a fixed clock and nonce" do
    public = <<4>> <> d64(@rfc7515_x) <> d64(@rfc7515_y)
    pem = ec_pem(d64(@rfc7515_d), public, :ECPrivateKey)
    {:ok, key} = JWT.parse_key(@key_id, pem)

    {:ok, token} =
      JWT.sign(key, "POST", "api.cdp.coinbase.com", "/platform/v2/x402/settle",
        now: @now,
        nonce: @nonce
      )

    {_, header, claims, sig, _, _} = parts(token)

    assert header == %{"alg" => "ES256", "kid" => @key_id, "nonce" => @nonce, "typ" => "JWT"}

    assert claims == %{
             "sub" => @key_id,
             "iss" => "cdp",
             "nbf" => @now,
             "iat" => @now,
             "exp" => @now + 120,
             "uris" => ["POST api.cdp.coinbase.com/platform/v2/x402/settle"]
           }

    refute Map.has_key?(claims, "aud")
    assert byte_size(sig) == 64
    assert valid?(token, public)
  end

  test "the default nonce is 16 random bytes in hex, new for every token" do
    {secret, _} = new_ed25519()
    {:ok, key} = JWT.parse_key(@key_id, secret)
    sign = fn -> JWT.sign(key, "POST", "api.cdp.coinbase.com", "/p", now: @now) end

    {:ok, a} = sign.()
    {:ok, b} = sign.()
    {_, %{"nonce" => na}, _, _, _, _} = parts(a)
    {_, %{"nonce" => nb}, _, _, _, _} = parts(b)

    assert na =~ ~r/\A[0-9a-f]{32}\z/
    assert na != nb
  end

  ## Round trips and refusals

  test "round trip: generated Ed25519, SEC1 and PKCS #8 keys" do
    for {secret, public} <- [new_ed25519(), new_ec(:ECPrivateKey), new_ec(:PrivateKeyInfo)] do
      {:ok, key} = JWT.parse_key(@key_id, secret)
      {:ok, token} = JWT.sign(key, "POST", "api.cdp.coinbase.com", "/platform/v2/x402/verify")
      assert valid?(token, public)

      # Another key's public half does not verify it.
      {_, other} = if key.alg == "EdDSA", do: new_ed25519(), else: new_ec()
      refute valid?(token, other)

      {_, _, claims, _, _, _} = parts(token)
      assert_in_delta claims["iat"], System.os_time(:second), 5
      assert claims["exp"] - claims["nbf"] == 120
    end
  end

  test "a PEM whose newlines arrive as literal \\n, as from an env var, is read" do
    {pem, public} = new_ec()
    {:ok, key} = JWT.parse_key(@key_id, String.replace(pem, "\n", "\\n"))
    {:ok, token} = JWT.sign(key, "POST", "api.cdp.coinbase.com", "/p")
    assert valid?(token, public)
  end

  test "keys in neither format, or damaged, are refused with an atom" do
    {public, seed} = :crypto.generate_key(:eddsa, :ed25519)
    {other_public, _} = :crypto.generate_key(:eddsa, :ed25519)
    {pub384, priv384} = :crypto.generate_key(:ecdh, :secp384r1)

    p384 =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(
          :ECPrivateKey,
          {:ECPrivateKey, 1, priv384, {:namedCurve, {1, 3, 132, 0, 34}}, pub384, :asn1_NOVALUE}
        )
      ])

    assert JWT.parse_key(@key_id, Base.encode64(seed)) == {:error, :unrecognized_key_format}

    assert JWT.parse_key(@key_id, ed25519_secret(seed, other_public)) ==
             {:error, :ed25519_public_key_mismatch}

    assert JWT.parse_key(
             @key_id,
             "-----BEGIN EC PRIVATE KEY-----\nnot a key\n-----END EC PRIVATE KEY-----\n"
           ) ==
             {:error, :unrecognized_key_format}

    assert JWT.parse_key(@key_id, p384) == {:error, :unsupported_curve}

    rsa = :public_key.generate_key({:rsa, 2048, 65_537})
    rsa_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa)])
    assert JWT.parse_key(@key_id, rsa_pem) == {:error, :unrecognized_key_format}
    assert JWT.parse_key(@key_id, "") == {:error, :missing_key_secret}
    assert JWT.parse_key("", Base.encode64(seed <> public)) == {:error, :missing_key_id}
  end

  test "a request part with whitespace, or a bad nonce, is refused" do
    {secret, _} = new_ed25519()
    {:ok, key} = JWT.parse_key(@key_id, secret)

    assert JWT.sign(key, "POST", "api.cdp.coinbase.com", "/a /b") == {:error, :invalid_request}
    assert JWT.sign(key, "POST", "api.cdp.coinbase.com\n", "/a") == {:error, :invalid_request}
    assert JWT.sign(key, "", "api.cdp.coinbase.com", "/a") == {:error, :invalid_request}
    assert JWT.sign(key, "POST", "h", "/a", nonce: "short") == {:error, :invalid_request}
  end

  ## The adapter: the header on verify and settle

  setup do
    offer = Fixtures.offer()
    {:ok, payment} = Payment.decode(Fixtures.header(Fixtures.payment(offer)))
    {:ok, payment} = Payment.match(payment, offer)

    %{
      request: Facilitator.request(payment, offer),
      config: [req_options: [plug: {Req.Test, __MODULE__}]]
    }
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp capture_requests(test) do
    stub(fn conn ->
      send(
        test,
        {:cdp, conn.scheme, conn.host, conn.request_path,
         Plug.Conn.get_req_header(conn, "authorization")}
      )

      body =
        if String.ends_with?(conn.request_path, "/verify"),
          do: Fixtures.verify_ok(),
          else: Fixtures.settle_ok()

      Req.Test.json(conn, body)
    end)
  end

  test "verify and settle each carry a fresh JWT bound to their own path",
       %{request: request, config: config} do
    capture_requests(self())
    {secret, public} = new_ed25519()

    config =
      config ++
        [key_id: fn -> @key_id end, key_secret: fn -> secret end, clock: fn -> @now end]

    assert {:ok, _} = CDP.verify(request, config)
    assert {:ok, _} = CDP.settle(request, config)

    for op <- ["verify", "settle"] do
      path = "/platform/v2/x402/" <> op
      assert_received {:cdp, :https, "api.cdp.coinbase.com", ^path, auth}
      token = bearer!(auth)
      {_, header, claims, _, _, _} = parts(token)

      assert valid?(token, public)
      assert header["kid"] == @key_id
      assert claims["uris"] == ["POST api.cdp.coinbase.com" <> path]
      assert claims["sub"] == @key_id
      assert claims["nbf"] == @now
      assert claims["exp"] == @now + 120
    end
  end

  test "a plain-string key id is accepted; a :url cannot move the JWT",
       %{request: request, config: config} do
    capture_requests(self())
    {pem, public} = new_ec()

    config =
      config ++
        [url: "https://evil.example/x402", key_id: @key_id, key_secret: fn -> pem end]

    assert {:ok, _} = CDP.verify(request, config)
    assert_received {:cdp, :https, "api.cdp.coinbase.com", "/platform/v2/x402/verify", auth}
    assert valid?(bearer!(auth), public)
  end

  test "misconfiguration sends nothing and is :invalid_config", %{
    request: request,
    config: config
  } do
    stub(fn _ -> flunk("no request should be sent") end)
    {secret, _} = new_ed25519()
    ok_secret = fn -> secret end

    for bad <- [
          [key_id: @key_id, key_secret: secret],
          [key_secret: ok_secret],
          [key_id: @key_id],
          [key_id: "", key_secret: ok_secret],
          [key_id: @key_id, key_secret: fn -> nil end],
          [key_id: @key_id, key_secret: fn -> raise "boom" end],
          [key_id: @key_id, key_secret: fn -> "not a key" end],
          [key_id: @key_id, key_secret: ok_secret, clock: fn -> :later end],
          [key_id: @key_id, key_secret: ok_secret, auth_headers: fn _, _, _ -> {:ok, []} end],
          []
        ] do
      capture_log(fn ->
        assert CDP.verify(request, config ++ bad) == {:error, :invalid_config}, inspect(bad)
        assert CDP.settle(request, config ++ bad) == {:error, :invalid_config}
      end)
    end
  end

  test "a bare-string secret is refused by name, even next to a usable key id",
       %{request: request, config: config} do
    stub(fn _ -> flunk("no request should be sent") end)
    {secret, _} = new_ed25519()

    log =
      capture_log(fn ->
        assert CDP.verify(request, config ++ [key_id: @key_id, key_secret: secret]) ==
                 {:error, :invalid_config}
      end)

    assert log =~ "key_secret_not_a_function"
    refute log =~ secret
  end

  test "the paths and URL agree with the host the token names" do
    assert CDP.url() == "https://" <> CDP.host() <> "/platform/v2/x402"
    assert CDP.url() <> "/verify" == "https://" <> CDP.host() <> CDP.path(:verify)
    assert CDP.url() <> "/settle" == "https://" <> CDP.host() <> CDP.path(:settle)
  end

  ## Secrets never printed

  test "the secret appears in no log line and no inspect output", %{
    request: request,
    config: config
  } do
    test = self()

    stub(fn conn ->
      send(test, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
    end)

    {ed_secret, _} = new_ed25519()
    {pem, _} = new_ec()
    pem_body = pem |> String.split("\n") |> Enum.at(1)

    log =
      capture_log([level: :debug], fn ->
        for secret <- [ed_secret, pem] do
          good = config ++ [key_id: @key_id, key_secret: fn -> secret end]
          assert CDP.verify(request, good) == {:error, {:http_status, 500}}

          # A secret function that raises with the secret in its message.
          raising = config ++ [key_id: @key_id, key_secret: fn -> raise secret end]
          assert CDP.verify(request, raising) == {:error, :invalid_config}

          # A damaged key, so the parser sees it and fails.
          damaged =
            config ++ [key_id: @key_id, key_secret: fn -> String.slice(secret, 0, 60) end]

          assert CDP.verify(request, damaged) == {:error, :invalid_config}

          {:ok, key} = JWT.parse_key(@key_id, secret)
          refute inspect(key) =~ secret
          refute inspect(key) =~ @key_id
          refute inspect(key, structs: false) =~ secret
          refute inspect(good) =~ secret
        end
      end)

    assert log =~ "x402 CDP facilitator not configured"

    for secret <- [ed_secret, pem_body, String.slice(ed_secret, 0, 20)] do
      refute log =~ secret
    end

    # Nor the bearer tokens it minted.
    assert_received {:auth, [first]}
    refute log =~ String.replace_prefix(first, "Bearer ", "")
  end

  test "a key's printed form, even as a raw term, shows no key material" do
    {public, seed} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, key} = JWT.parse_key(@key_id, ed25519_secret(seed, public))
    printed = :io_lib.format(~c"~w", [Map.from_struct(key)]) |> IO.iodata_to_binary()

    assert printed =~ "#Fun<"
    refute printed =~ Enum.join(:binary.bin_to_list(seed), ",")
  end
end
