defmodule FolioWeb.DashboardLive do
  @moduledoc """
  The single-portfolio dashboard: portfolio value/profit chart, per-asset
  holdings, and the transaction form. All screens are live actions on this
  LiveView so the window/mode/currency selections survive navigation; they
  deliberately live in assigns, not the URL.
  """

  use FolioWeb, :live_view

  alias Folio.Analytics
  alias Folio.Analytics.Grid
  alias Folio.Assets
  alias Folio.Assets.Candidate
  alias Folio.Portfolios
  alias Folio.Portfolios.Transaction

  @sparkline_max_points 48

  @impl true
  def mount(_params, _session, socket) do
    dashboard = Application.get_env(:folio, :dashboard, [])
    %{user: user} = socket.assigns.current_scope
    portfolio = Portfolios.default_portfolio_for(user.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Folio.PubSub, Folio.MarketData.topic())
    end

    {:ok,
     socket
     |> assign(
       page_title: "Folio",
       window: Keyword.get(dashboard, :window, :"1w"),
       mode: Keyword.get(dashboard, :mode, :value),
       currency: Keyword.get(dashboard, :currency, "EUR"),
       portfolio_id: portfolio.id
     )
     |> stream_configure(:holdings, dom_id: &"asset-#{&1.asset_id}")
     |> stream(:holdings, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("select_window", %{"window" => window}, socket) do
    window = Enum.find(Grid.windows(), socket.assigns.window, &(Atom.to_string(&1) == window))

    {:noreply, socket |> assign(window: window) |> refresh_dashboard()}
  end

  def handle_event("select_mode", %{"mode" => mode}, socket) do
    mode = if mode == "profit", do: :profit, else: :value

    {:noreply, socket |> assign(mode: mode) |> push_chart_data()}
  end

  def handle_event("select_currency", %{"currency" => currency}, socket) do
    currency = if currency == "USD", do: "USD", else: "EUR"

    {:noreply, socket |> assign(currency: currency) |> refresh_dashboard()}
  end

  def handle_event("search_asset", %{"query" => query}, socket) do
    query = String.trim(query)
    socket = assign(socket, search_query: query, asset_error: nil)

    if query == "" do
      {:noreply, assign(socket, search_results: [])}
    else
      {:noreply, start_async(socket, :asset_search, fn -> Assets.resolve(query) end)}
    end
  end

  def handle_event("select_candidate", %{"index" => index}, socket) do
    case Enum.at(socket.assigns.search_results, String.to_integer(index)) do
      nil ->
        {:noreply, socket}

      candidate ->
        {:noreply,
         socket
         |> assign(
           selected_candidate: candidate,
           search_results: [],
           search_query: "",
           asset_error: nil,
           txn_currency: candidate.quote_currency || socket.assigns.currency
         )
         |> recompute_total()}
    end
  end

  def handle_event("clear_asset", _params, socket) do
    {:noreply, assign(socket, selected_candidate: nil, search_query: "", search_results: [])}
  end

  def handle_event("manual_entry", _params, socket) do
    {:noreply, assign(socket, asset_entry_mode: :manual, asset_error: nil)}
  end

  def handle_event("search_entry", _params, socket) do
    {:noreply, assign(socket, asset_entry_mode: :search, asset_error: nil)}
  end

  def handle_event("set_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, txn_type: parse_type(type))}
  end

  def handle_event("validate", %{"transaction" => params} = _all, socket) do
    {params, socket} = normalize_txn_params(params, socket)

    changeset =
      socket
      |> base_transaction()
      |> Portfolios.change_transaction(params)
      |> Map.put(:action, :validate)

    {:noreply, socket |> assign(form: to_form(changeset)) |> recompute_total()}
  end

  def handle_event("save", %{"transaction" => params} = all_params, socket) do
    {params, socket} = normalize_txn_params(params, socket)

    with {:ok, asset_id} <- resolve_asset_id(socket, all_params["manual"]),
         {:ok, _transaction} <- persist_transaction(socket, Map.put(params, "asset_id", asset_id)) do
      {:noreply,
       socket
       |> put_flash(:info, "Transaction saved")
       |> push_patch(to: ~p"/")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(form: to_form(changeset)) |> recompute_total()}

      {:error, :no_asset} ->
        {:noreply, assign(socket, asset_error: "Choose an asset first")}

      {:error, :asset_invalid} ->
        {:noreply,
         assign(socket, asset_error: "The asset could not be created - check the fields")}
    end
  end

  def handle_event("delete_transaction", _params, socket) do
    {:ok, _deleted} = Portfolios.delete_transaction(socket.assigns.transaction)

    {:noreply,
     socket
     |> put_flash(:info, "Transaction deleted")
     |> push_patch(to: ~p"/")}
  end

  @impl true
  def handle_info({:prices_updated, _asset_id}, socket), do: {:noreply, maybe_refresh(socket)}
  def handle_info({:fx_updated, _currency}, socket), do: {:noreply, maybe_refresh(socket)}

  @impl true
  def handle_async(:asset_search, {:ok, candidates}, socket) do
    {:noreply, assign(socket, search_results: candidates)}
  end

  def handle_async(:asset_search, {:exit, _reason}, socket) do
    {:noreply, assign(socket, search_results: [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%= case @live_action do %>
        <% :index -> %>
          <div class="drawer">
            <input id="app-drawer" type="checkbox" class="drawer-toggle" />
            <div class="drawer-content flex min-h-dvh flex-col">
              <header class="sticky top-0 z-10 flex items-center bg-base-100/95 px-4 py-3 backdrop-blur">
                <label for="app-drawer" class="btn btn-ghost btn-sm btn-square" aria-label="Menu">
                  <.icon name="hero-bars-3" class="size-5" />
                </label>
              </header>

              <div class="px-6 pt-2">
                <div class="text-sm font-medium text-base-content/50">Portfolio value</div>
                <div
                  id="portfolio-value"
                  class={[
                    "text-[40px] font-bold leading-tight tracking-tight tabular-nums lg:text-[48px]",
                    @empty? && "text-base-content/30"
                  ]}
                >
                  {money(@summary.value, @currency)}
                </div>
                <div
                  :if={not @empty?}
                  id="portfolio-change"
                  class={[
                    "mt-1 text-[15px] font-semibold tabular-nums",
                    change_class(@summary.change_abs)
                  ]}
                >
                  {change_arrow(@summary.change_abs)} {money_abs(@summary.change_abs, @currency)}
                  <span :if={@summary.change_pct} class="font-medium">
                    ({percent(@summary.change_pct)})
                  </span>
                </div>
              </div>

              <%= if @empty? do %>
                <div
                  id="empty-state"
                  class="flex flex-1 flex-col items-center justify-center gap-3 px-10 pb-24 text-center"
                >
                  <div class="flex h-14 w-14 items-center justify-center rounded-full bg-primary/10 text-primary">
                    <.icon name="hero-plus" class="size-6" />
                  </div>
                  <div class="text-[18px] font-semibold">Nothing here yet</div>
                  <p
                    class="text-[14px] leading-relaxed text-base-content/55"
                    style="text-wrap: pretty;"
                  >
                    Add your first buy and your portfolio, chart and profit will appear here &mdash; everything stays on your server.
                  </p>
                  <.link patch={~p"/transactions/new"} class="btn btn-primary mt-2 rounded-full px-6">
                    Add first transaction
                  </.link>
                </div>
              <% else %>
                <div
                  id="portfolio-chart"
                  phx-hook="PortfolioChart"
                  phx-update="ignore"
                  class="mt-4 h-40 w-full lg:h-[220px]"
                >
                </div>

                <div class="mt-3 flex flex-col gap-3 px-6">
                  <div class="flex rounded-full bg-base-200 p-1 tabular-nums">
                    <button
                      :for={window <- Grid.windows()}
                      type="button"
                      id={"window-#{window}"}
                      phx-click="select_window"
                      phx-value-window={window}
                      class={[
                        "flex-1 cursor-pointer rounded-full py-1.5 text-xs font-semibold",
                        if(window == @window,
                          do: "bg-base-100 shadow-sm",
                          else: "text-base-content/50"
                        )
                      ]}
                    >
                      {window_label(window)}
                    </button>
                  </div>
                  <div class="flex justify-end">
                    <div class="flex rounded-full bg-base-200 p-0.5 text-[11px] font-semibold">
                      <button
                        :for={mode <- [:value, :profit]}
                        type="button"
                        id={"mode-#{mode}"}
                        phx-click="select_mode"
                        phx-value-mode={mode}
                        class={[
                          "cursor-pointer rounded-full px-3 py-1",
                          if(mode == @mode, do: "bg-base-100 shadow-sm", else: "text-base-content/50")
                        ]}
                      >
                        {mode |> Atom.to_string() |> String.capitalize()}
                      </button>
                    </div>
                  </div>
                </div>

                <div id="holdings" phx-update="stream" class="mt-4 flex flex-col gap-2.5 px-4 pb-28">
                  <div
                    id="holdings-empty"
                    class="hidden py-8 text-center text-sm text-base-content/50 only:block"
                  >
                    No open positions
                  </div>
                  <.asset_card
                    :for={{id, holding} <- @streams.holdings}
                    id={id}
                    holding={holding}
                    currency={@currency}
                  />
                </div>
              <% end %>

              <.link
                id="fab-add"
                patch={~p"/transactions/new"}
                class="btn btn-primary btn-circle absolute bottom-8 right-6 h-14 w-14 shadow-lg"
                aria-label="Add transaction"
              >
                <.icon name="hero-plus" class="size-6" />
              </.link>
            </div>

            <div class="drawer-side z-20">
              <label for="app-drawer" aria-label="Close menu" class="drawer-overlay"></label>
              <aside class="flex min-h-dvh w-[300px] flex-col rounded-r-3xl bg-base-200 shadow-2xl">
                <div class="flex items-center gap-3 px-5 pb-5 pt-8">
                  <div class="flex h-11 w-11 items-center justify-center rounded-full bg-primary/15 text-lg font-bold text-primary">
                    {@current_scope.user.username |> String.first() |> String.upcase()}
                  </div>
                  <div>
                    <div class="text-[15px] font-semibold">{@current_scope.user.username}</div>
                    <div class="text-[12px] text-base-content/45">Personal ledger</div>
                  </div>
                </div>
                <div class="mx-5 border-t border-base-300"></div>
                <div class="flex flex-col gap-1 px-3 py-3">
                  <div class="flex items-center justify-between rounded-xl px-2 py-3">
                    <span class="flex items-center gap-3 text-[15px] font-medium">
                      <.icon name="hero-sun" class="size-[18px] opacity-60" /> Theme
                    </span>
                    <Layouts.theme_toggle />
                  </div>
                  <div class="flex items-center justify-between rounded-xl px-2 py-3">
                    <span class="flex items-center gap-3 text-[15px] font-medium">
                      <.icon name="hero-globe-alt" class="size-[18px] opacity-60" /> Currency
                    </span>
                    <div class="flex rounded-full bg-base-200 p-0.5 text-[11px] font-semibold tabular-nums">
                      <button
                        :for={currency <- ["EUR", "USD"]}
                        type="button"
                        id={"currency-#{currency}"}
                        phx-click="select_currency"
                        phx-value-currency={currency}
                        class={[
                          "cursor-pointer rounded-full px-3 py-1",
                          if(currency == @currency,
                            do: "bg-base-100 shadow-sm",
                            else: "text-base-content/50"
                          )
                        ]}
                      >
                        {currency}
                      </button>
                    </div>
                  </div>
                </div>
                <div class="mx-5 border-t border-base-300"></div>
                <div class="flex-1"></div>
                <div class="px-5 pb-8 text-[12px] text-base-content/35">
                  v0.1 &middot; self-hosted
                </div>
              </aside>
            </div>
          </div>
        <% :asset -> %>
          <header class="sticky top-0 z-10 flex items-center gap-1 bg-base-100/95 px-4 py-3 backdrop-blur">
            <.link patch={~p"/"} class="btn btn-ghost btn-sm btn-square" aria-label="Back">
              <.icon name="hero-chevron-left" class="size-5" />
            </.link>
            <span class="text-[17px] font-semibold">
              {@asset.name}
              <span class="text-[13px] font-medium text-base-content/40">{@asset.symbol}</span>
            </span>
          </header>
          <div id="asset-transactions" class="flex flex-col gap-2.5 px-4 pb-16 pt-2">
            <.link
              :for={transaction <- @transactions}
              id={"transaction-#{transaction.id}"}
              patch={~p"/transactions/#{transaction.id}/edit"}
              class="flex items-center justify-between rounded-2xl bg-base-200/60 px-4 py-3.5"
            >
              <div>
                <div class="flex items-center gap-2 text-[15px] font-semibold">
                  <span class={[
                    "badge badge-sm badge-soft",
                    if(transaction.type == :buy, do: "badge-success", else: "badge-error")
                  ]}>
                    {transaction.type |> Atom.to_string() |> String.upcase()}
                  </span>
                  <span class="tabular-nums">
                    {quantity(transaction.quantity)} @ {money(
                      transaction.price_per_unit,
                      transaction.currency
                    )}
                  </span>
                </div>
                <div class="mt-0.5 text-[13px] text-base-content/50 tabular-nums">
                  {Calendar.strftime(transaction.executed_at, "%d %b %Y · %H:%M")}
                  <span :if={not Decimal.eq?(transaction.fee, 0)}>
                    &middot; fee {money(transaction.fee, transaction.currency)}
                  </span>
                </div>
              </div>
              <.icon name="hero-chevron-right" class="size-4 opacity-40" />
            </.link>
            <p :if={@transactions == []} class="py-8 text-center text-sm text-base-content/50">
              No transactions for this asset.
            </p>
          </div>
        <% _new_or_edit -> %>
          <header class="sticky top-0 z-10 flex items-center gap-1 bg-base-100/95 px-4 py-3 backdrop-blur">
            <.link patch={~p"/"} class="btn btn-ghost btn-sm btn-square" aria-label="Back">
              <.icon name="hero-chevron-left" class="size-5" />
            </.link>
            <span class="text-[17px] font-semibold">
              {if @transaction, do: "Edit transaction", else: "Add transaction"}
            </span>
          </header>

          <div class="flex flex-col gap-4 px-5 pb-8 pt-2">
            <div class="relative">
              <span class="mb-1.5 block text-[13px] font-medium text-base-content/60">Asset</span>
              <%= if @selected_candidate do %>
                <div
                  id="selected-asset"
                  class="input input-lg flex w-full items-center justify-between rounded-xl"
                >
                  <span class="truncate text-[15px] font-semibold">
                    {@selected_candidate.name}
                    <span class="text-[13px] font-medium text-base-content/45">
                      {@selected_candidate.symbol}<span :if={@selected_candidate.exchange}> &middot; {@selected_candidate.exchange}</span>
                    </span>
                  </span>
                  <button
                    type="button"
                    id="clear-asset"
                    phx-click="clear_asset"
                    aria-label="Clear asset"
                    class="cursor-pointer opacity-40 hover:opacity-100"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
              <% else %>
                <form
                  :if={@asset_entry_mode == :search}
                  id="asset-search-form"
                  phx-change="search_asset"
                  onsubmit="return false;"
                >
                  <label class="input input-lg flex w-full items-center gap-2 rounded-xl">
                    <.icon name="hero-magnifying-glass" class="size-[18px] opacity-40" />
                    <input
                      type="text"
                      name="query"
                      value={@search_query}
                      phx-debounce="300"
                      autocomplete="off"
                      placeholder="Search name or ticker"
                      aria-label="Search asset"
                      class="grow text-[16px]"
                    />
                  </label>
                </form>
                <div
                  :if={@asset_entry_mode == :search and @search_results != []}
                  id="asset-candidates"
                  class="absolute left-0 right-0 top-full z-10 mt-1.5 overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-xl"
                >
                  <button
                    :for={{candidate, index} <- Enum.with_index(@search_results)}
                    type="button"
                    id={"candidate-#{index}"}
                    phx-click="select_candidate"
                    phx-value-index={index}
                    class={[
                      "flex w-full cursor-pointer flex-col gap-0.5 px-4 py-3 text-left",
                      index == 0 && "bg-base-200/70"
                    ]}
                  >
                    <span class="text-[15px] font-semibold">{candidate.name}</span>
                    <span class="text-[12px] text-base-content/50">{candidate_meta(candidate)}</span>
                  </button>
                </div>
              <% end %>
              <p :if={@asset_error} id="asset-error" class="mt-1.5 text-sm text-error">
                {@asset_error}
              </p>
              <button
                :if={is_nil(@selected_candidate)}
                type="button"
                id="toggle-entry-mode"
                phx-click={if @asset_entry_mode == :manual, do: "search_entry", else: "manual_entry"}
                class="mt-1.5 cursor-pointer text-[13px] text-base-content/50 underline"
              >
                {if @asset_entry_mode == :manual, do: "Back to search", else: "Enter ticker manually"}
              </button>
            </div>

            <.form
              for={@form}
              id="transaction-form"
              phx-change="validate"
              phx-submit="save"
              class={[
                "flex flex-col gap-4",
                (is_nil(@selected_candidate) and @asset_entry_mode == :search and
                   @search_query != "") && "opacity-40"
              ]}
            >
              <div
                :if={@asset_entry_mode == :manual and is_nil(@selected_candidate)}
                id="manual-asset-fields"
                class="grid grid-cols-2 gap-3"
              >
                <div>
                  <span class="mb-1.5 block text-[13px] font-medium text-base-content/60">Ticker</span>
                  <.input
                    type="text"
                    name="manual[symbol]"
                    id="manual-symbol"
                    value=""
                    class="input input-lg w-full rounded-xl text-[16px]"
                  />
                </div>
                <div>
                  <span class="mb-1.5 block text-[13px] font-medium text-base-content/60">Name</span>
                  <.input
                    type="text"
                    name="manual[name]"
                    id="manual-name"
                    value=""
                    class="input input-lg w-full rounded-xl text-[16px]"
                  />
                </div>
                <div>
                  <span class="mb-1.5 block text-[13px] font-medium text-base-content/60">Kind</span>
                  <.input
                    type="select"
                    name="manual[kind]"
                    id="manual-kind"
                    value="stock"
                    options={[{"Stock", "stock"}, {"ETF", "etf"}]}
                    class="select select-lg w-full rounded-xl text-[16px]"
                  />
                </div>
                <div>
                  <span class="mb-1.5 block text-[13px] font-medium text-base-content/60">
                    Exchange (optional)
                  </span>
                  <.input
                    type="text"
                    name="manual[exchange]"
                    id="manual-exchange"
                    value=""
                    class="input input-lg w-full rounded-xl text-[16px]"
                  />
                </div>
                <div>
                  <span class="mb-1.5 block text-[13px] font-medium text-base-content/60">
                    Quote currency
                  </span>
                  <.input
                    type="text"
                    name="manual[quote_currency]"
                    id="manual-quote-currency"
                    value={@txn_currency}
                    class="input input-lg w-full rounded-xl text-[16px]"
                  />
                </div>
              </div>

              <input type="hidden" name={@form[:type].name} value={@txn_type} />
              <div class="flex rounded-full bg-base-200 p-1 text-[14px] font-semibold">
                <button
                  :for={type <- [:buy, :sell]}
                  type="button"
                  id={"type-#{type}"}
                  phx-click="set_type"
                  phx-value-type={type}
                  class={[
                    "flex-1 cursor-pointer rounded-full py-2",
                    if(type == @txn_type, do: "bg-base-100 shadow-sm", else: "text-base-content/50")
                  ]}
                >
                  {type |> Atom.to_string() |> String.capitalize()}
                </button>
              </div>

              <div class="grid grid-cols-2 gap-3">
                <div>
                  <span class="mb-1.5 block text-[13px] font-medium text-base-content/60">Date</span>
                  <.input
                    type="date"
                    name="transaction[date]"
                    id="txn-date"
                    value={@date}
                    class="input input-lg w-full rounded-xl text-[16px] tabular-nums"
                  />
                </div>
                <div>
                  <span class="mb-1.5 block text-[13px] font-medium text-base-content/60">Time</span>
                  <.input
                    type="time"
                    name="transaction[time]"
                    id="txn-time"
                    value={@time}
                    class="input input-lg w-full rounded-xl text-[16px] tabular-nums"
                  />
                </div>
              </div>
              <p
                :for={error <- @form[:executed_at].errors}
                :if={@form.source.action}
                class="text-sm text-error"
              >
                {translate_error(error)}
              </p>

              <div class="grid grid-cols-2 gap-3">
                <div>
                  <span class="mb-1.5 block text-[13px] font-medium text-base-content/60">
                    Quantity
                  </span>
                  <.input
                    field={@form[:quantity]}
                    type="text"
                    inputmode="decimal"
                    class="input input-lg w-full rounded-xl text-[16px] tabular-nums"
                  />
                </div>
                <div>
                  <span class="mb-1.5 block text-[13px] font-medium text-base-content/60">
                    Price per unit
                  </span>
                  <.input
                    field={@form[:price_per_unit]}
                    type="text"
                    inputmode="decimal"
                    class="input input-lg w-full rounded-xl text-[16px] tabular-nums"
                  />
                </div>
              </div>

              <div class="grid grid-cols-2 gap-3">
                <div>
                  <span class="mb-1.5 block text-[13px] font-medium text-base-content/60">Fee</span>
                  <.input
                    field={@form[:fee]}
                    type="text"
                    inputmode="decimal"
                    class="input input-lg w-full rounded-xl text-[16px] tabular-nums"
                  />
                </div>
                <div>
                  <span class="mb-1.5 block text-[13px] font-medium text-base-content/60">
                    Currency
                  </span>
                  <.input
                    field={@form[:currency]}
                    type="select"
                    options={currency_options(@txn_currency)}
                    value={@form[:currency].value || @txn_currency}
                    class="select select-lg w-full rounded-xl text-[16px]"
                  />
                </div>
              </div>

              <div
                :if={@total}
                id="txn-total"
                class="flex justify-between rounded-xl bg-base-200/60 px-4 py-3 text-[14px] tabular-nums"
              >
                <span class="text-base-content/55">Total</span>
                <span class="font-semibold">
                  {money(@total.amount, @total.currency)}
                  <span :if={@total.converted} class="font-medium text-base-content/45">
                    &asymp; {money(@total.converted, @currency)}
                  </span>
                </span>
              </div>

              <button
                type="submit"
                id="save-transaction"
                class="btn btn-primary btn-lg mt-1 w-full rounded-xl"
                phx-disable-with="Saving..."
              >
                Save transaction
              </button>
              <button
                :if={@transaction}
                type="button"
                id="delete-transaction"
                phx-click="delete_transaction"
                data-confirm="Delete this transaction?"
                class="btn btn-ghost btn-lg w-full rounded-xl text-error"
              >
                Delete transaction
              </button>
            </.form>
          </div>
      <% end %>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :holding, :map, required: true
  attr :currency, :string, required: true

  defp asset_card(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={~p"/assets/#{@holding.asset_id}"}
      class="flex items-center gap-3 rounded-2xl bg-base-200/60 px-4 py-3.5"
    >
      <div class="min-w-0 flex-1">
        <div class="truncate text-[15px] font-semibold">
          {@holding.name}
          <span class="text-[13px] font-medium text-base-content/40">{@holding.symbol}</span>
        </div>
        <div class="text-[13px] text-base-content/50 tabular-nums">{quantity_line(@holding)}</div>
      </div>
      <%= if @holding.has_data? do %>
        <svg
          :if={@holding.sparkline}
          viewBox="0 0 96 28"
          class={["h-7 w-20 shrink-0 lg:h-8 lg:w-32", change_class(@holding.change_abs)]}
          aria-hidden="true"
        >
          <polyline
            points={@holding.sparkline}
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linejoin="round"
            stroke-linecap="round"
          />
        </svg>
        <div class="shrink-0 text-right lg:w-48">
          <div class="text-[15px] font-semibold tabular-nums">{money(@holding.value, @currency)}</div>
          <div class={["text-[13px] font-medium tabular-nums", change_class(@holding.change_abs)]}>
            {change_arrow(@holding.change_abs)} {money_abs(@holding.change_abs, @currency)}
            <span :if={@holding.change_pct}>({percent(@holding.change_pct)})</span>
          </div>
        </div>
      <% else %>
        <div class="shrink-0 text-right text-[13px] text-base-content/40" data-role="no-data">
          No price data yet
        </div>
      <% end %>
    </.link>
    """
  end

  defp apply_action(socket, :index, _params), do: refresh_dashboard(socket)

  defp apply_action(socket, :asset, %{"asset_id" => asset_id}) do
    asset = Assets.get_asset!(String.to_integer(asset_id))
    transactions = Portfolios.list_transactions(socket.assigns.portfolio_id, asset_id: asset.id)

    assign(socket, asset: asset, transactions: transactions)
  end

  defp apply_action(socket, :new, _params), do: init_form(socket, %Transaction{}, nil)

  defp apply_action(socket, :edit, %{"id" => id}) do
    transaction = Portfolios.get_transaction!(socket.assigns.portfolio_id, String.to_integer(id))
    candidate = Candidate.from_asset(Assets.get_asset!(transaction.asset_id))

    init_form(socket, transaction, candidate)
  end

  defp maybe_refresh(%{assigns: %{live_action: :index}} = socket), do: refresh_dashboard(socket)
  defp maybe_refresh(socket), do: socket

  defp refresh_dashboard(socket) do
    %{portfolio_id: portfolio_id, window: window, currency: currency} = socket.assigns
    holdings = Analytics.holdings(portfolio_id, window, currency)

    socket
    |> assign(
      summary: Analytics.summary(portfolio_id, window, currency),
      empty?: not Portfolios.any_transactions?(portfolio_id),
      holdings_empty?: holdings == []
    )
    |> stream(
      :holdings,
      Enum.map(holdings, &Map.put(&1, :sparkline, sparkline_points(&1.series))),
      reset: true
    )
    |> push_chart_data()
  end

  defp push_chart_data(socket) do
    %{portfolio_id: portfolio_id, window: window, currency: currency, mode: mode} = socket.assigns

    series =
      case mode do
        :value -> Analytics.value_series(portfolio_id, window, currency)
        :profit -> Analytics.profit_series(portfolio_id, window, currency)
      end

    push_event(socket, "chart:data", %{
      points:
        Enum.map(series, &%{time: DateTime.to_unix(&1.at), value: Decimal.to_float(&1.value)}),
      mode: Atom.to_string(mode),
      currency: currency
    })
  end

  # -- transaction form state ------------------------------------------------

  defp init_form(socket, transaction, candidate) do
    executed_at = transaction.executed_at || DateTime.truncate(DateTime.utc_now(), :second)

    socket
    |> assign(
      transaction: if(transaction.id, do: transaction),
      form: to_form(Portfolios.change_transaction(transaction)),
      selected_candidate: candidate,
      search_query: "",
      search_results: [],
      asset_entry_mode: :search,
      asset_error: nil,
      txn_type: transaction.type || :buy,
      date: executed_at |> DateTime.to_date() |> Date.to_iso8601(),
      time: executed_at |> DateTime.to_time() |> Time.to_iso8601() |> String.slice(0, 5),
      txn_currency: form_currency(transaction, candidate, socket.assigns.currency)
    )
    |> recompute_total()
  end

  defp form_currency(%Transaction{currency: currency}, _candidate, _display)
       when is_binary(currency),
       do: currency

  defp form_currency(_transaction, %Candidate{quote_currency: currency}, _display)
       when is_binary(currency),
       do: currency

  defp form_currency(_transaction, _candidate, display), do: display

  defp base_transaction(%{assigns: %{transaction: %Transaction{} = transaction}}), do: transaction
  defp base_transaction(_socket), do: %Transaction{}

  defp normalize_txn_params(params, socket) do
    date = Map.get(params, "date", socket.assigns.date)
    time = Map.get(params, "time", socket.assigns.time)
    type = Map.get(params, "type", Atom.to_string(socket.assigns.txn_type))

    params =
      params
      |> Map.drop(["date", "time"])
      |> Map.put("executed_at", executed_at_param(date, time))

    {params, assign(socket, date: date, time: time, txn_type: parse_type(type))}
  end

  defp executed_at_param(date, time) do
    with {:ok, date} <- Date.from_iso8601(date),
         {:ok, time} <- Time.from_iso8601(pad_time(time)) do
      DateTime.new!(date, time, "Etc/UTC")
    else
      _invalid -> nil
    end
  end

  defp pad_time(time) when byte_size(time) == 5, do: time <> ":00"
  defp pad_time(time), do: time

  defp parse_type("sell"), do: :sell
  defp parse_type(_type), do: :buy

  defp resolve_asset_id(%{assigns: %{asset_entry_mode: :manual}}, manual_params) do
    case Assets.create_manual_asset(manual_attrs(manual_params)) do
      {:ok, asset} -> {:ok, asset.id}
      {:error, _changeset} -> {:error, :asset_invalid}
    end
  end

  defp resolve_asset_id(%{assigns: %{selected_candidate: nil}}, _manual), do: {:error, :no_asset}

  defp resolve_asset_id(%{assigns: %{selected_candidate: %Candidate{} = candidate}}, _manual) do
    case candidate.local_asset_id do
      nil ->
        case Assets.create_asset(Candidate.to_attrs(candidate)) do
          {:ok, asset} -> {:ok, asset.id}
          {:error, _changeset} -> {:error, :asset_invalid}
        end

      asset_id ->
        {:ok, asset_id}
    end
  end

  defp manual_attrs(params) do
    params = params || %{}

    %{
      symbol: params["symbol"] || "",
      name: params["name"] || "",
      kind: if(params["kind"] == "etf", do: :etf, else: :stock),
      exchange: presence(params["exchange"]),
      quote_currency: params["quote_currency"] || ""
    }
  end

  defp presence(nil), do: nil
  defp presence(string), do: if(String.trim(string) == "", do: nil, else: string)

  defp persist_transaction(%{assigns: %{transaction: %Transaction{} = transaction}}, params) do
    Portfolios.update_transaction(transaction, params)
  end

  defp persist_transaction(%{assigns: %{portfolio_id: portfolio_id}}, params) do
    Portfolios.create_transaction(portfolio_id, params)
  end

  defp recompute_total(socket) do
    changeset = socket.assigns.form.source
    quantity = Ecto.Changeset.get_field(changeset, :quantity)
    price = Ecto.Changeset.get_field(changeset, :price_per_unit)
    fee = Ecto.Changeset.get_field(changeset, :fee) || Decimal.new(0)
    currency = Ecto.Changeset.get_field(changeset, :currency) || socket.assigns.txn_currency

    total =
      if match?(%Decimal{}, quantity) and match?(%Decimal{}, price) do
        amount = quantity |> Decimal.mult(price) |> Decimal.add(fee)

        %{
          amount: amount,
          currency: currency,
          converted: converted_total(amount, currency, socket.assigns.currency)
        }
      end

    assign(socket, total: total)
  end

  defp converted_total(_amount, currency, currency), do: nil

  defp converted_total(amount, currency, display_currency),
    do: Analytics.convert(amount, currency, display_currency)

  # -- presentation helpers --------------------------------------------------

  defp candidate_meta(%Candidate{} = candidate) do
    [candidate.symbol, candidate.exchange, candidate.quote_currency]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" \u00b7 ")
  end

  defp currency_options(txn_currency), do: Enum.uniq(["EUR", "USD", txn_currency])

  defp window_label(:ytd), do: "YTD"
  defp window_label(window), do: Atom.to_string(window)

  defp quantity_line(%{kind: :crypto, symbol: symbol, quantity: quantity}),
    do: "#{quantity(quantity)} #{symbol}"

  defp quantity_line(%{quantity: quantity}), do: "#{quantity(quantity)} shares"

  defp gain?(change), do: not Decimal.negative?(change)

  defp change_class(change), do: if(gain?(change), do: "text-success", else: "text-error")

  defp change_arrow(change), do: if(gain?(change), do: "▲", else: "▼")

  defp sparkline_points(series) when length(series) < 2, do: nil

  defp sparkline_points(series) do
    values = series |> downsample(@sparkline_max_points) |> Enum.map(& &1.value)
    n = length(values)
    min = Enum.min(values, Decimal)
    range = Decimal.sub(Enum.max(values, Decimal), min)

    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {value, i} ->
      x = (i * 96) |> Decimal.new() |> Decimal.div(n - 1) |> Decimal.round(2)
      "#{Decimal.to_string(x, :normal)},#{y_coord(value, min, range)}"
    end)
  end

  defp downsample(series, max_points) do
    n = length(series)

    if n <= max_points do
      series
    else
      sampled = Enum.take_every(series, div(n + max_points - 1, max_points))
      last = List.last(series)

      if List.last(sampled) == last, do: sampled, else: sampled ++ [last]
    end
  end

  # Vertical placement inside the 0..28 viewBox with 2px padding; a flat
  # series sits on the midline.
  defp y_coord(_value, _min, %Decimal{coef: 0}), do: "14"

  defp y_coord(value, min, range) do
    value
    |> Decimal.sub(min)
    |> Decimal.div(range)
    |> Decimal.mult(24)
    |> then(&Decimal.sub(Decimal.new(26), &1))
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
  end
end
