defmodule X402.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/afomi/x402_ex"

  def project do
    [
      app: :x402_ex,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "x402 v2 payments for Plug apps: offers, payment checks, facilitator calls, " <>
          "a replay guard and Stripe recording.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      mod: {X402.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.15"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "x402 spec" => "https://github.com/coinbase/x402"
      },
      files:
        ~w(lib docs/SPEC_NOTES.md mix.exs README.md CHANGELOG.md SECURITY.md CONTRIBUTING.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "SECURITY.md",
        "CONTRIBUTING.md",
        "docs/SPEC_NOTES.md",
        LICENSE: [title: "License"]
      ]
    ]
  end
end
