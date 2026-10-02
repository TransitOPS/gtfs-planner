defmodule GtfsPlanner.Alerts.MessageAnswer do
  @moduledoc """
  What a rider reads, embedded in `service_alerts.message`.

  `header` names the effect and the place in one line; `description` adds the
  cause, the time and what to do instead. Both are plain text an editor wrote or
  accepted from a script, so neither is rendered as markup.

  `url` is optional and is validated as a full web address: only `http` and
  `https` with a nonempty host, which is what keeps a `javascript:` or `data:`
  value out of the stored alert and out of anything that later shows it to a
  rider.

  `script_key` records which script produced the text and `fact_digest` the facts
  it was generated from, so the editor can flag wording that a later answer made
  stale. Neither is derived content.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.ChangesetHelpers

  @primary_key false

  @max_header_length 120
  @max_description_length 2_000

  embedded_schema do
    field :header, :string
    field :description, :string
    field :url, :string
    field :script_key, :string
    field :customized, :boolean
    field :fact_digest, :string
  end

  @type t :: %__MODULE__{
          header: String.t() | nil,
          description: String.t() | nil,
          url: String.t() | nil,
          script_key: String.t() | nil,
          customized: boolean() | nil,
          fact_digest: String.t() | nil
        }

  @doc """
  Creates a changeset for the message answer.

  Requires nothing, because a draft is saved at every step. Bounds the header at
  #{@max_header_length} characters and the description at #{@max_description_length},
  and accepts a `url` only when it is an `http` or `https` address with a host.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:header, :description, :url, :script_key, :customized, :fact_digest])
    |> ChangesetHelpers.trim_string_fields()
    |> validate_length(:header, max: @max_header_length)
    |> validate_length(:description, max: @max_description_length)
    |> ChangesetHelpers.validate_http_url(:url)
  end
end
