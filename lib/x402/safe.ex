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
end
