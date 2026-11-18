defmodule X402.Safe do
  @moduledoc false

  # Runs a callback from an adapter or the app and turns every way it can
  # fail (raise, throw, exit) into a value, so a failure after money has
  # moved cannot crash the process that holds the record. Only the kind of
  # failure is returned; the reason might carry a request or a secret.

  @spec call((-> term())) :: {:ok, term()} | {:caught, :error | :throw | :exit}
  def call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    kind, _reason -> {:caught, kind}
  end

  # A reason from an adapter, a guard or the app, as a short token safe to
  # log: an atom, or the tag of a small tuple. Never the whole term, which
  # might carry a request, a row or a secret.
  @spec reason(term()) :: String.t()
  def reason(why) when is_atom(why), do: Atom.to_string(why)
  def reason({tag, n}) when is_atom(tag) and is_integer(n), do: "#{tag}_#{n}"
  def reason({:caught, kind}) when is_atom(kind), do: "caught_#{kind}"

  def reason(tuple) when is_tuple(tuple) and is_atom(elem(tuple, 0)),
    do: Atom.to_string(elem(tuple, 0))

  def reason(_), do: "other"
end
