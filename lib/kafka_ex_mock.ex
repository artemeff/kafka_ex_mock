defmodule KafkaExMock do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(KafkaExMock.Server, [])
    ]

    :meck.new(KafkaEx, [:unstick, :passthrough])
    :meck.expect(KafkaEx, :create_worker, fn name, worker_init ->
        KafkaExMock.Server.create_worker(name, worker_init)
    end)
    # :meck.expect(KafkaEx, :consumer_group, fn(worker) -> :ok end)
    # :meck.expect(KafkaEx, :metadata, fn(opts) -> :ok end)
    # :meck.expect(KafkaEx, :consumer_group_metadata, fn(worker_name, supplied_consumer_group) -> :ok end)
    :meck.expect(KafkaEx, :latest_offset, fn topic, partition ->
      KafkaExMock.Server.latest_offset(topic, partition)
    end)
    :meck.expect(KafkaEx, :fetch, fn topic, partition, opts ->
      KafkaExMock.Server.fetch(topic, partition, opts)
    end)
    :meck.expect(KafkaEx, :fetch, fn topic, partition ->
      KafkaExMock.Server.fetch(topic, partition)
    end)
    :meck.expect(KafkaEx, :produce, fn topic, partition, value ->
      KafkaExMock.Server.produce(topic, partition, value)
    end)
    :meck.expect(KafkaEx, :stream, fn topic, partition, opts ->
      KafkaExMock.Server.stream(topic, partition, opts)
    end)

    opts = [strategy: :one_for_one, name: KafkaExMock.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def stop(_state) do
    # unload meck
  end
end
