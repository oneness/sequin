defmodule Sequin.ConsumersRuntime.ConsumerProducer do
  @moduledoc false
  @behaviour Broadway.Producer

  use GenStage

  alias Broadway.Message
  alias Ecto.Adapters.SQL.Sandbox
  alias Sequin.Consumers.ConsumerEvent
  alias Sequin.Consumers.ConsumerEventData
  alias Sequin.Consumers.ConsumerRecord
  alias Sequin.Consumers.ConsumerRecordData
  alias Sequin.Consumers.SinkConsumer
  alias Sequin.ConsumersRuntime.ConsumerIdempotency
  alias Sequin.DatabasesRuntime.SlotMessageStore
  alias Sequin.Postgres
  alias Sequin.Repo
  alias Sequin.Time
  alias Sequin.Tracer

  require Logger

  @impl GenStage
  def init(opts) do
    consumer = Keyword.fetch!(opts, :consumer)
    Logger.info("Initializing consumer producer", consumer_id: consumer.id)

    if test_pid = Keyword.get(opts, :test_pid) do
      Sandbox.allow(Sequin.Repo, test_pid, self())
      Mox.allow(Sequin.TestSupport.DateTimeMock, test_pid, self())
    end

    consumer = Repo.lazy_preload(consumer, postgres_database: [:replication_slot])

    :syn.join(:consumers, {:messages_ingested, consumer.id}, self())

    state = %{
      demand: 0,
      consumer: consumer,
      receive_timer: nil,
      trim_timer: nil,
      batch_size: Keyword.get(opts, :batch_size, 10),
      batch_timeout: Keyword.get(opts, :batch_timeout, :timer.seconds(10)),
      test_pid: test_pid,
      scheduled_handle_demand: false
    }

    state = schedule_receive_messages(state)
    state = schedule_trim_idempotency(state)

    {:producer, state}
  end

  @impl GenStage
  def handle_demand(incoming_demand, %{demand: demand} = state) do
    new_state = maybe_schedule_demand(state)
    new_state = %{new_state | demand: demand + incoming_demand}

    {:noreply, [], new_state}
  end

  @impl GenStage
  def handle_info(:handle_demand, state) do
    handle_receive_messages(%{state | scheduled_handle_demand: false})
  end

  @impl GenStage
  def handle_info(:receive_messages, state) do
    new_state = schedule_receive_messages(state)
    handle_receive_messages(new_state)
  end

  @impl GenStage
  def handle_info(:messages_ingested, state) do
    new_state = maybe_schedule_demand(state)
    {:noreply, [], new_state}
  end

  @impl GenStage
  def handle_info(:trim_idempotency, state) do
    %SinkConsumer{} = consumer = state.consumer

    case Postgres.confirmed_flush_lsn(consumer.postgres_database) do
      {:ok, nil} ->
        :ok

      {:ok, lsn} ->
        ConsumerIdempotency.trim(state.consumer.id, lsn)

      {:error, error} ->
        Logger.error("Error trimming idempotency seqs", error: error)
    end

    {:noreply, [], schedule_trim_idempotency(state)}
  end

  defp handle_receive_messages(%{demand: demand} = state) when demand > 0 do
    messages = produce_messages(state.consumer, demand * state.batch_size)

    Logger.debug(
      "Received #{length(messages)} messages for consumer #{state.consumer.id} (demand: #{demand}, batch_size: #{state.batch_size})"
    )

    {state, messages} = handle_idempotency(state, messages)

    broadway_messages =
      messages
      |> Enum.chunk_every(state.batch_size)
      |> Enum.map(fn batch ->
        %Message{
          data: batch,
          acknowledger: {__MODULE__, {state.consumer, state.test_pid}, nil}
        }
      end)

    new_demand = demand - length(broadway_messages)
    new_demand = if new_demand < 0, do: 0, else: new_demand

    {:noreply, broadway_messages, %{state | demand: new_demand}}
  end

  defp handle_receive_messages(state) do
    {:noreply, [], state}
  end

  defp produce_messages(%SinkConsumer{} = consumer, count) do
    case SlotMessageStore.produce(consumer.id, count) do
      {:ok, messages} ->
        Tracer.Server.messages_received(consumer, messages)
        messages

      {:error, _error} ->
        []
    end
  end

  defp handle_idempotency(state, messages) do
    seqs_to_deliver =
      messages
      |> Stream.reject(fn
        # We don't enforce idempotency for read actions
        %ConsumerEvent{data: %ConsumerEventData{action: :read}} -> true
        %ConsumerRecord{data: %ConsumerRecordData{action: :read}} -> true
        # We only recently added :action to ConsumerRecordData, so we need to ignore
        # any messages that don't have it for backwards compatibility
        %ConsumerRecord{data: %ConsumerRecordData{action: nil}} -> true
        _ -> false
      end)
      |> Enum.map(& &1.seq)

    {:ok, delivered_seqs} = ConsumerIdempotency.delivered_messages(state.consumer.id, seqs_to_deliver)
    {delivered_messages, filtered_messages} = Enum.split_with(messages, &(&1.seq in delivered_seqs))

    if delivered_messages == [] do
      {state, messages}
    else
      Logger.warning(
        "Received #{length(delivered_seqs)} messages for consumer #{state.consumer.id} that have already been delivered",
        seqs: delivered_seqs
      )

      SlotMessageStore.ack(state.consumer, Enum.map(delivered_messages, & &1.ack_id))

      # If we filtered out any messages due to idempotency, we will have additional
      # demand that we need to handle. So we schedule an immediate :receive_messages
      if state.receive_timer, do: Process.cancel_timer(state.receive_timer)
      send(self(), :receive_messages)

      {%{state | receive_timer: nil}, filtered_messages}
    end
  end

  defp schedule_receive_messages(state) do
    receive_timer = Process.send_after(self(), :receive_messages, state.batch_timeout)
    %{state | receive_timer: receive_timer}
  end

  defp schedule_trim_idempotency(state) do
    trim_timer = Process.send_after(self(), :trim_idempotency, :timer.seconds(30))
    %{state | trim_timer: trim_timer}
  end

  @impl Broadway.Producer
  def prepare_for_draining(%{receive_timer: receive_timer, trim_timer: trim_timer} = state) do
    if receive_timer, do: Process.cancel_timer(receive_timer)
    if trim_timer, do: Process.cancel_timer(trim_timer)
    {:noreply, [], %{state | receive_timer: nil, trim_timer: nil}}
  end

  @exponential_backoff_max :timer.minutes(3)
  def ack({consumer, test_pid}, successful, failed) do
    successful_seqs = successful |> Stream.flat_map(& &1.data) |> Enum.map(& &1.seq)
    :ok = ConsumerIdempotency.mark_messages_delivered(consumer.id, successful_seqs)

    successful_ids = successful |> Stream.flat_map(& &1.data) |> Enum.map(& &1.ack_id)
    failed_ids = failed |> Stream.flat_map(& &1.data) |> Enum.map(& &1.ack_id)

    if test_pid do
      Sandbox.allow(Sequin.Repo, test_pid, self())
    end

    if length(successful_ids) > 0 do
      SlotMessageStore.ack(consumer, successful_ids)
    end

    failed
    |> Enum.flat_map(fn message ->
      Enum.map(message.data, fn record ->
        deliver_count = record.deliver_count
        backoff_time = Time.exponential_backoff(:timer.seconds(1), deliver_count, @exponential_backoff_max)
        not_visible_until = DateTime.add(DateTime.utc_now(), backoff_time, :millisecond)

        {record.ack_id, not_visible_until}
      end)
    end)
    |> Enum.chunk_every(1000)
    |> Enum.each(fn chunk ->
      ack_ids_with_not_visible_until = Map.new(chunk)
      SlotMessageStore.nack(consumer.id, ack_ids_with_not_visible_until)
    end)

    if test_pid do
      send(test_pid, {__MODULE__, :ack_finished, successful_ids, failed_ids})
    end

    :ok
  end

  defp maybe_schedule_demand(%{scheduled_handle_demand: false} = state) do
    Process.send_after(self(), :handle_demand, 10)
    %{state | scheduled_handle_demand: true}
  end

  defp maybe_schedule_demand(state), do: state
end
