defmodule Chromesmith do
  @moduledoc """
  Main module for Chromesmith.

  > Add Chromesmith to your application supervision tree:

      defmodule ChromesmithExample.Application do
        use Application

        def start(_type, _args) do
          children = [
            Chromesmith.child_spec(:chrome_pool, [process_pool_size: 2, page_pool_size: 1])
          ]

          opts = [strategy: :one_for_one, name: ChromesmithExample.Supervisor]
          Supervisor.start_link(children, opts)
        end
      end

  Using `Chromesmith.child_spec/2`, you can provide multiple options to configure the pool:

  * `:process_pool_size` - How many Chrome instances to open
  * `:page_pool_size` - How many pages to open per chrome instance
  """
  use GenServer
  alias ChromeRemoteInterface.{Session, PageSession}

  defstruct [
    supervisor: nil, # Chromesmith.Supervisor PID
    process_pool_size: 0, # How many Headless Chrome instances to spawn
    page_pool_size: 0, # How many Pages per Instance
    process_pools: [], # List of process pool tuples, {pid, available_pids, all_pids}
    chrome_options: [],
    checkout_queue: :queue.new()
  ]

  @type t :: %__MODULE__{
    supervisor: pid(),
    process_pool_size: non_neg_integer(),
    page_pool_size: non_neg_integer(),
    process_pools: [{pid(), [pid()], [pid()]}],
    chrome_options: list(),
    checkout_queue: :queue.queue()
  }

  @doc """
  Check out a Page from one of the headless chrome processes.
  """
  @spec checkout(pid(), boolean()) :: {:ok, pid()} | {:error, :none_available} | {:error, :timeout}
  def checkout(pid, should_block \\ false, timeout \\ :infinity)
  def checkout(pid, false, _) do
    GenServer.call(pid, {:checkout, false})
  end
  def checkout(pid, true, timeout) do
    GenServer.call(pid, {:checkout, true}, timeout)
  end

  @doc """
  Check in a Page that has completed work.
  """
  def checkin(pid, worker) do
    GenServer.cast(pid, {:checkin, worker})
  end

  def purge(pid, worker) do
    GenServer.cast(pid, {:purge, worker})
  end

  def info(pid) do
    GenServer.call(pid, {:info})
  end

  # ---
  # Private
  # ---

  def child_spec(name, opts) do
    %{
      id: name,
      start: {__MODULE__, :start_link, [opts, [name: name]]},
      type: :worker
    }
  end

  def start_link(opts, start_opts \\ []) do
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  def init(opts) when is_list(opts) do
    {:ok, supervisor_pid} = Chromesmith.Supervisor.start_link(opts)

    state = %Chromesmith{
      supervisor: supervisor_pid,
      process_pool_size: Keyword.get(opts, :process_pool_size, 4),
      page_pool_size: Keyword.get(opts, :page_pool_size, 16),
      chrome_options: Keyword.get(opts, :chrome_options, [])
    }

    init(state)
  end

  def init(%Chromesmith{} = state) do
    process_pools = spawn_pools(state.supervisor, state)
    {:ok, %{state | process_pools: process_pools}}
  end

  def spawn_pools(supervisor, state) do[ManyE]
    children =
      Enum.map(1..state.process_pool_size, fn(index) ->
        start_worker(supervisor, index, state)
      end)

    children
  end

  def start_worker(supervisor, index, state) do
    {:ok, child} = Supervisor.start_child(
      supervisor,
      %{
        id: index,
        start: {Chromesmith.Worker, :start_link, [
          index,
          state.chrome_options
        ]},
        restart: :permanent,
        shutdown: 5000,
        type: :worker
      }
    )

    {session, page_pids} =
      child
      |> Chromesmith.Worker.start_pages([page_pool_size: state.page_pool_size])

    {child, page_pids, page_pids, session}
  end

  # ---
  # GenServer Handlers
  # ----

  def handle_call({:info}, _from, state) do
    {:reply, {:ok, state} }
  end

  def handle_call({:checkout, should_block}, from, state) do
    {updated_pools, page} =
      state.process_pools
      |> Enum.reduce({[], nil}, fn({pid, available_pages, total_pages, session} = pool, {pools, found_page}) ->
        if is_nil(found_page) and length(available_pages) > 0 do
          [checked_out_page | new_pages] = available_pages
          new_pool = {pid, new_pages, total_pages, session}
          {[new_pool | pools], checked_out_page}
        else
          {[pool | pools], found_page}
        end
      end)

    # If page available, return with page
    # Else, we will enqueue the request.
    if page do
      {:reply, {:ok, page}, %{state | process_pools: updated_pools}}
    else
      if should_block do
        {:noreply, %{state | checkout_queue: :queue.in(from, state.checkout_queue)}}
      else
        {:reply, {:error, :none_available}, state}
      end
    end
  end

  def handle_cast({:checkin, page}, state) do
    # If there's a checkout process waiting, immediate give page to queued process.

    case :queue.out(state.checkout_queue) do
      {{:value, ref}, new_queue} ->
        GenServer.reply(ref, {:ok, page})
        {:noreply, %{state | checkout_queue: new_queue}}
      {:empty, _} ->
        updated_pools =
          state.process_pools
          |> Enum.map(fn({pid, available_pages, total_pages, session} = pool) ->
            # If this page is from this pool, (part of total pages)
            # then return it as an available page only if it hasn't
            # been added before (not already checked into available_pages

            if Enum.find(total_pages, &(&1 == page)) && !Enum.find(available_pages, &(&1 == page)) do
              {pid, [page | available_pages], total_pages, session}
            else
              pool
            end
          end)

        {:noreply, %{state | process_pools: updated_pools}}
    end
  end

  def handle_cast({:purge, page}, state) do
    updated_pools =
      state.process_pools
      |> Enum.map(fn({pid, _available_pages, total_pages, session} = pool) ->
        # If this page is from this pool, (part of total pages)
        # then return it as an available page only if it hasn't
        # been added before (not already checked into available_pages

        if Enum.find(total_pages, &(&1 == page)) do
          {:ok, page} = Session.new_page(session)
          {:ok, page_session} = PageSession.start_link(page)

          {pid, [page_session], [page_session], session}
        else
          pool
        end
      end)

    new_state = %{state | process_pools: updated_pools}

    case :queue.out(state.checkout_queue) do
      {{:value, ref}, new_queue} ->
        {updated_pools, page} =
          new_state.process_pools
          |> Enum.reduce({[], nil}, fn({pid, available_pages, total_pages, session} = pool, {pools, found_page}) ->
            if is_nil(found_page) and length(available_pages) > 0 do
              [checked_out_page | new_pages] = available_pages
              new_pool = {pid, new_pages, total_pages, session}
              {[new_pool | pools], checked_out_page}
            else
              {[pool | pools], found_page}
            end
          end)
        GenServer.reply(ref, {:ok, page})
        new_state = %{new_state | checkout_queue: new_queue}
        {:noreply, %{new_state | process_pools: updated_pools}}
      {:empty, _} ->
        {:noreply, new_state}
    end
  end
end
