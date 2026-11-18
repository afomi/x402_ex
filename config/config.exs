import Config

# The Req.Test seam (`:req_options`) is allowed in this library's own tests only.
# An app that uses x402_ex sets this in its own config/test.exs, never in prod.
if config_env() == :test do
  config :x402_ex, allow_req_options: true
end
