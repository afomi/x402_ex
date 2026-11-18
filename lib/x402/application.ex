defmodule X402.Application do
  @moduledoc false

  # One Task.Supervisor, so `X402.handle/2` can run settle-and-record in a
  # process that outlives the request: a client that disconnects mid-settle
  # kills its request process, and the record must still be written.

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([{Task.Supervisor, name: X402.TaskSupervisor}],
      strategy: :one_for_one,
      name: X402.Supervisor
    )
  end
end
