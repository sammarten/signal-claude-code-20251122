defmodule Signal.Repo do
  use Ecto.Repo,
    otp_app: :signal,
    adapter: Ecto.Adapters.Postgres
end
