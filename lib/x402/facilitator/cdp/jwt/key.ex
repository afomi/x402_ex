defmodule X402.Facilitator.CDP.JWT.Key do
  @moduledoc """
  A parsed CDP API key. The private key lives only inside `:sign`, a closure,
  so it cannot be printed; `inspect/1` shows the algorithm alone.
  """

  @enforce_keys [:key_id, :alg, :sign]
  defstruct [:key_id, :alg, :sign]

  @type t :: %__MODULE__{key_id: String.t(), alg: String.t(), sign: (binary() -> binary())}

  defimpl Inspect do
    def inspect(%{alg: alg}, _opts), do: "#X402.Facilitator.CDP.JWT.Key<alg: #{alg}, redacted>"
  end
end
