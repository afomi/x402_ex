defmodule X402.Facilitator.CDP.JWT do
  @moduledoc """
  The short-lived bearer JWT that Coinbase Developer Platform (CDP) takes on
  each REST request, built the way CDP's own SDK builds it.

  We follow `GenerateJWT` in `coinbase/cdp-sdk` `go/auth/jwt.go`, which the
  x402 reference's CDP facilitator client calls
  (`go/legacy/pkg/coinbasefacilitator/cdp.go`, `CreateAuthHeader`), and which
  the TypeScript `generateJwt` (`typescript/packages/cdp-sdk/src/auth/utils/jwt.ts`)
  matches claim for claim:

  Protected header, keys in Go's (sorted) order:

      {"alg":"EdDSA" | "ES256","kid":<key id>,"nonce":<32 hex chars>,"typ":"JWT"}

  Claims, keys in Go's (sorted) order:

      {"exp":<now + 120>,"iat":<now>,"iss":"cdp","nbf":<now>,"sub":<key id>,
       "uris":["<METHOD> <host><path>"]}

  `nonce` is 16 random bytes in lowercase hex. No `aud` claim is sent, as the
  SDKs send none unless asked. The token lasts 120 seconds, the SDKs' default.

  Two key formats, as CDP issues them and as the SDKs read them:

    * Ed25519 (`alg` `EdDSA`): standard base64 of 64 bytes, the 32-byte seed
      then the 32-byte public key. We check that the public half is the one
      the seed derives, so a damaged key is refused rather than used.
    * ECDSA P-256 (`alg` `ES256`): a PEM `EC PRIVATE KEY` (SEC1, what CDP
      issues) or `PRIVATE KEY` (PKCS #8). The signature is the JWS form,
      `r || s`, 32 bytes each (RFC 7518 section 3.4).

  A literal `\\n` in the secret is read as a newline, as the Python SDK does,
  since a PEM in an environment variable often arrives that way.

  The secret is parsed into a `X402.Facilitator.CDP.JWT.Key`, which holds the
  private key only inside a signing closure, so neither `inspect/1` nor an
  Erlang crash report can print it. Every failure is an atom; no error carries
  the secret or the parsing library's exception.
  """

  alias X402.Facilitator.CDP.JWT.Key

  @expires_in 120
  @p256 {1, 2, 840, 10045, 3, 1, 7}

  @type error ::
          :missing_key_id
          | :missing_key_secret
          | :unrecognized_key_format
          | :ed25519_public_key_mismatch
          | :unsupported_curve
          | :encrypted_key
          | :invalid_request
          | :signing_failed

  @doc "How long a token lasts, in seconds: 120, the CDP SDKs' default."
  def expires_in, do: @expires_in

  @doc """
  Parses a CDP API key secret into a signing key.

  `key_id` is the API key's id (`organizations/…/apiKeys/…` or a bare UUID),
  sent as `kid` and `sub`. `key_secret` is the secret as CDP gave it.
  """
  @spec parse_key(String.t(), String.t()) :: {:ok, Key.t()} | {:error, error()}
  def parse_key(key_id, _secret) when not is_binary(key_id) or key_id == "",
    do: {:error, :missing_key_id}

  def parse_key(_key_id, secret) when not is_binary(secret) or secret == "",
    do: {:error, :missing_key_secret}

  def parse_key(key_id, secret) do
    secret = secret |> String.replace("\\n", "\n") |> String.trim()

    result =
      if String.starts_with?(secret, "-----BEGIN"),
        do: parse_pem(secret),
        else: parse_ed25519(secret)

    case result do
      {:ok, alg, sign} -> {:ok, %Key{key_id: key_id, alg: alg, sign: sign}}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unrecognized_key_format}
  end

  defp parse_ed25519(secret) do
    with {:ok, <<seed::binary-32, public::binary-32>>} <- Base.decode64(secret),
         {^public, _} <- :crypto.generate_key(:eddsa, :ed25519, seed) do
      {:ok, "EdDSA", fn input -> :crypto.sign(:eddsa, :none, input, [seed, :ed25519]) end}
    else
      {other, _} when is_binary(other) -> {:error, :ed25519_public_key_mismatch}
      _ -> {:error, :unrecognized_key_format}
    end
  end

  defp parse_pem(secret) do
    case :public_key.pem_decode(secret) do
      [{type, _der, :not_encrypted} = entry | _] when type in [:ECPrivateKey, :PrivateKeyInfo] ->
        entry |> :public_key.pem_entry_decode() |> ec_key()

      [{_type, _der, cipher} | _] when cipher != :not_encrypted ->
        {:error, :encrypted_key}

      _ ->
        {:error, :unrecognized_key_format}
    end
  end

  defp ec_key({:ECPrivateKey, _version, private, {:namedCurve, @p256}, _public, _attrs})
       when is_binary(private) and byte_size(private) <= 32 do
    private = pad(private, 32)
    {:ok, "ES256", fn input -> es256(input, private) end}
  end

  defp ec_key({:ECPrivateKey, _, _, _, _, _}), do: {:error, :unsupported_curve}
  defp ec_key(_), do: {:error, :unrecognized_key_format}

  # :crypto gives a DER ECDSA-Sig-Value; JWS wants r || s, fixed width.
  defp es256(input, private) do
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    <<r::unsigned-big-256, s::unsigned-big-256>>
  end

  defp pad(bin, size), do: :binary.copy(<<0>>, size - byte_size(bin)) <> bin

  @doc """
  A signed JWT for one request: `method` (e.g. `"POST"`), `host`
  (`"api.cdp.coinbase.com"`, no scheme) and `path` (`"/platform/v2/x402/verify"`).

  Options, for tests: `:now` (Unix seconds; default the system clock) and
  `:nonce` (32 lowercase hex characters; default 16 random bytes).
  """
  @spec sign(Key.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, error()}
  def sign(%Key{} = key, method, host, path, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)
    nonce = Keyword.get_lazy(opts, :nonce, fn -> random_nonce() end)

    if request_part?(method) and request_part?(host) and request_part?(path) and
         is_integer(now) and now > 0 and nonce?(nonce) do
      header =
        ordered(alg: key.alg, kid: key.key_id, nonce: nonce, typ: "JWT")

      claims =
        ordered(
          exp: now + @expires_in,
          iat: now,
          iss: "cdp",
          nbf: now,
          sub: key.key_id,
          uris: [uri(method, host, path)]
        )

      input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
      signature(key, input)
    else
      {:error, :invalid_request}
    end
  end

  defp signature(key, input) do
    {:ok, input <> "." <> b64(key.sign.(input))}
  rescue
    _ -> {:error, :signing_failed}
  end

  @doc """
  The `uris` entry: `"<METHOD> <host><path>"`, one space, as all three SDKs
  build it.
  """
  def uri(method, host, path), do: "#{method} #{host}#{path}"

  @doc false
  # Signs an arbitrary JWS signing input; for checking the primitives against
  # published test vectors (RFC 8037 A.4).
  def sign_input(%Key{} = key, input) when is_binary(input), do: key.sign.(input)

  # No whitespace or control characters, so the claim says exactly one request.
  defp request_part?(s),
    do: is_binary(s) and s != "" and not String.match?(s, ~r/[\s\x00-\x1f\x7f]/)

  defp nonce?(n), do: is_binary(n) and n =~ ~r/\A[0-9a-f]{32}\z/

  defp random_nonce, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp ordered(pairs),
    do: Jason.OrderedObject.new(Enum.map(pairs, fn {k, v} -> {to_string(k), v} end))

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
