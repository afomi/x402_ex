defmodule X402.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :x402_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "x402 v2 payments for Plug apps: offers, payment checks, facilitator calls, " <>
          "a replay guard and Stripe recording."
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.15"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
