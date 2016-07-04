defmodule KafkaExMock.Server do
  use GenServer

  defmodule Message do
    defstruct offset: 0, value: nil
  end

  defmodule Topic do
    defstruct name: nil, offset: 0, messages: []
  end

  defmodule State do
    defstruct topics: %{}, event_pid: nil
  end

  def start_link do
    topics = Application.get_env(:kafka_ex_mock, :topics, [])

    start_link(topics)
  end

  def start_link(topic_names) do
    topics = topic_names_for_state(topic_names)

    GenServer.start_link(__MODULE__, %State{topics: topics}, name: __MODULE__)
  end

  def stop do
    GenServer.stop(__MODULE__)
  end

  def create_worker(name, _worker_init) do
    topic_names = Application.get_env(:kafka_ex_mock, :topics, [])
    topics = topic_names_for_state(topic_names)

    GenServer.start_link(__MODULE__, %State{topics: topics}, name: name)
  end

  def dump do
    GenServer.call(__MODULE__, :dump)
  end

  def produce(topic_name, _partition, payload, _opts \\ []) do
    GenServer.call(__MODULE__, {:produce, topic_name, payload})
  end

  def stream(topic_name, partition, opts \\ []) do
    worker_name = Keyword.get(opts, :worker_name, __MODULE__)
    offset = Keyword.get(opts, :offset, 0)

    handler = KafkaExMock.Handler
    handler_init = []

    event_stream = GenServer.call(worker_name, {:create_stream, handler, handler_init})

    send(worker_name, {:start_streaming, topic_name, partition, offset})

    event_stream
  end

  def latest_offset(topic_name, _partition) do
    GenServer.call(__MODULE__, {:latest_offset, topic_name})
  end

  def fetch(topic_name, _partition, opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)

    GenServer.call(__MODULE__, {:fetch, topic_name, offset})
  end

  # GenServer

  def init(state) do
    {:ok, state}
  end

  def handle_call(:dump, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:latest_offset, topic_name}, _from, state) do
    {:reply, get_latest_offset(Map.get(state.topics, topic_name)), state}
  end

  def handle_call({:create_stream, handler, handler_init}, _from, state) do
    state = if state.event_pid && Process.alive?(state.event_pid) do
      # info = Process.info(self)
      # Logger.log(:warn, "'#{info[:registered_name]}' already streaming handler '#{handler}'")
      state
    else
      {:ok, event_pid}  = GenEvent.start_link
      :ok = GenEvent.add_handler(event_pid, handler, handler_init)
      %{state | event_pid: event_pid}
    end
    {:reply, GenEvent.stream(state.event_pid), state}
  end

  def handle_call({:produce, topic_name, payload}, _from, state) do
    {_, topics} = Map.get_and_update(state.topics, topic_name, fn topic ->
      case topic do
        nil ->
          message = %Message{offset: 0, value: payload}
          {topic, %Topic{name: topic_name, offset: 0, messages: [message]}}
        topic ->
          offset = topic.offset + 1
          message = %Message{offset: offset, value: payload}
          {topic, %{topic|offset: offset, messages: topic.messages ++ [message]}}
      end
    end)

    {:reply, :ok, %{state|topics: topics}}
  end

  def handle_call({:fetch, topic_name, offset}, _from, state) do
    {:reply, wrap_fetch_response(offset, Map.get(state.topics, topic_name)), state}
  end

  def handle_call(_request, _from, state) do
    {:noreply, state}
  end

  def handle_info({:start_streaming, topic, partition, offset}, state) do
    offset = case fetch(topic, partition, offset: offset) do
      :topic_not_found ->
        offset
      response ->
        message = response |> hd |> Map.get(:partitions) |> hd
        Enum.each(message.message_set, fn(message_set) ->
          GenEvent.notify(state.event_pid, message_set)
        end)
        case message.last_offset do
          nil         -> offset
          last_offset -> last_offset + 1
        end
    end

    Process.send_after(self, {:start_streaming, topic, partition, offset}, 100)

    {:noreply, state}
  end

  # internal functions

  defp get_latest_offset(nil) do
    :topic_not_found
  end
  defp get_latest_offset(topic) do
    [
      %KafkaEx.Protocol.Offset.Response{partition_offsets: [
        %{error_code: 0, offset: [topic.offset], partition: 0}
      ], topic: topic.name}
    ]
  end

  defp wrap_message(offset, payload) do
    %KafkaEx.Protocol.Fetch.Message{
      attributes: 0, crc: 0, key: nil,
      offset: offset, value: payload
    }
  end

  defp wrap_fetch_response(_offset, nil) do
    :topic_not_found
  end
  defp wrap_fetch_response(offset, topic) do
    messages = Enum.reduce(topic.messages, [], fn(message, acc) ->
      if message.offset >= offset do
        acc ++ [wrap_message(offset, message.value)]
      else
        acc
      end
    end)

    response = %KafkaEx.Protocol.Fetch.Response{topic: topic.name, partitions: [
      %{error_code: :no_error, hw_mark_offset: 115, message_set: messages, last_offset: topic.offset}
    ]}

    [response]
  end

  defp topic_names_for_state(topic_names) do
    topic_names
    |> Enum.map(fn name -> {name, %Topic{name: name}} end)
    |> Map.new
  end
end
