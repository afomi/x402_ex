defmodule X402.Codec do
  @moduledoc """
  Base64 JSON, the encoding of every x402 v2 HTTP header.

  The v2 HTTP transport carries `PAYMENT-REQUIRED`, `PAYMENT-SIGNATURE` and
  `PAYMENT-RESPONSE` as base64-encoded JSON (docs/SPEC_NOTES.md, "Headers").

  Decoding treats its input as hostile:

    * the encoded string is capped at `max_bytes` before any work is done;
    * only the standard base64 alphabet is accepted, padded or not;
    * JSON is decoded with string keys only, so no atoms are created;
    * the decoded value must be a JSON object.
  """

  @default_max_bytes 8_192

  @doc "The default cap on an encoded header, in bytes."
  def default_max_bytes, do: @default_max_bytes

  @doc "Encodes a map as base64 (standard alphabet, padded) JSON."
  @spec encode(map()) :: String.t()
  def encode(map) when is_map(map) do
    map |> Jason.encode!() |> Base.encode64()
  end

  @doc """
  Decodes base64 JSON into a map with string keys.

  Returns `{:error, :header_too_large | :invalid_base64 | :invalid_json | :not_an_object}`.
  """
  @spec decode(term(), pos_integer()) ::
          {:ok, map()}
          | {:error, :header_too_large | :invalid_base64 | :invalid_json | :not_an_object}
  def decode(encoded, max_bytes \\ @default_max_bytes)

  def decode(encoded, max_bytes) when is_binary(encoded) and byte_size(encoded) > max_bytes,
    do: {:error, :header_too_large}

  def decode(encoded, _max_bytes) when is_binary(encoded) do
    with {:ok, json} <- decode_base64(encoded),
         {:ok, value} <- decode_json(json) do
      if is_map(value), do: {:ok, value}, else: {:error, :not_an_object}
    end
  end

  def decode(_other, _max_bytes), do: {:error, :invalid_base64}

  defp decode_base64(encoded) do
    case Base.decode64(encoded) do
      {:ok, json} ->
        {:ok, json}

      :error ->
        case Base.decode64(encoded, padding: false) do
          {:ok, json} -> {:ok, json}
          :error -> {:error, :invalid_base64}
        end
    end
  end

  defp decode_json(json) do
    if String.valid?(json) do
      case Jason.decode(json, keys: :strings) do
        {:ok, value} -> {:ok, value}
        {:error, _} -> {:error, :invalid_json}
      end
    else
      {:error, :invalid_json}
    end
  end
end
