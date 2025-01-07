defmodule Sequin.HealthTest do
  use Sequin.DataCase, async: true

  alias Sequin.Error
  alias Sequin.ErrorFactory
  alias Sequin.Factory
  alias Sequin.Factory.AccountsFactory
  alias Sequin.Factory.ConsumersFactory
  alias Sequin.Factory.DatabasesFactory
  alias Sequin.Factory.ErrorFactory
  alias Sequin.Factory.ReplicationFactory
  alias Sequin.Health
  alias Sequin.Health.Event

  describe "initializes a new health" do
    test "initializes a new health" do
      entity = ConsumersFactory.sink_consumer(id: Factory.uuid(), inserted_at: DateTime.utc_now())
      assert {:ok, %Health{} = health} = Health.health(entity)
      assert health.status == :waiting
      assert is_list(health.checks) and length(health.checks) > 0
    end
  end

  describe "put_event/2" do
    test "updates the health of an entity with a health event" do
      entity = ConsumersFactory.http_endpoint(id: Factory.uuid(), inserted_at: DateTime.utc_now())

      assert {:ok, %Health{} = health} = Health.health(entity)
      assert health.status == :initializing

      assert :ok = Health.put_event(entity, %Event{slug: :endpoint_reachable, status: :success})
      assert {:ok, %Health{} = health} = Health.health(entity)
      assert health.status == :healthy
    end

    test "updates the health of a SinkConsumer with health events" do
      entity = ConsumersFactory.sink_consumer(id: Factory.uuid(), inserted_at: DateTime.utc_now())

      assert {:ok, %Health{} = health} = Health.health(entity)
      assert health.status == :waiting

      assert :ok = Health.put_event(entity, %Event{slug: :messages_filtered, status: :success})
      assert {:ok, %Health{} = health} = Health.health(entity)
      assert health.status == :waiting

      assert Enum.find(health.checks, &(&1.slug == :messages_filtered)).status == :healthy

      for slug <- [:messages_ingested, :messages_pending_delivery] do
        assert :ok = Health.put_event(entity, %Event{slug: slug, status: :success})
      end

      assert {:ok, %Health{} = health} = Health.health(entity)
      # If one remaining check is waiting, the health status should be waiting
      assert health.status == :waiting

      assert :ok = Health.put_event(entity, %Event{slug: :messages_delivered, status: :success})
      assert {:ok, %Health{} = health} = Health.health(entity)
      assert health.status == :healthy
    end

    test "health is in error if something is erroring" do
      entity = ConsumersFactory.sink_consumer(id: Factory.uuid(), inserted_at: DateTime.utc_now())

      assert :ok = Health.put_event(entity, %Event{slug: :sink_config_checked, status: :success})

      assert :ok =
               Health.put_event(entity, %Event{
                 slug: :messages_ingested,
                 status: :fail,
                 error: ErrorFactory.random_error()
               })
    end

    test "raises an error for unexpected events" do
      entity = ConsumersFactory.sink_consumer(id: Factory.uuid(), inserted_at: DateTime.utc_now())

      assert_raise ArgumentError, fn ->
        Health.put_event(entity, %Event{slug: :unexpected_event, status: :success})
      end
    end
  end

  describe "health/1" do
    test ":postgres_database :reachable goes into error if not present after 5 minutes of creation" do
      entity =
        ReplicationFactory.postgres_replication(
          id: Factory.uuid(),
          inserted_at: DateTime.add(DateTime.utc_now(), -6, :minute)
        )

      assert {:ok, health} = Health.health(entity)

      assert health.status == :error
    end
  end

  describe "to_external/1" do
    test "converts the health to an external format" do
      entity = ConsumersFactory.sink_consumer(id: Factory.uuid(), inserted_at: DateTime.utc_now())

      assert {:ok, %Health{} = health} = Health.health(entity)
      assert external = Health.to_external(health)
      assert external.status == :initializing

      assert :ok =
               Health.put_event(entity, %Event{
                 slug: :messages_ingested,
                 status: :fail,
                 error: ErrorFactory.random_error()
               })

      assert {:ok, %Health{} = health} = Health.health(entity)
      assert external = Health.to_external(health)
      assert external.status == :error
      assert Enum.find(external.checks, &(not is_nil(&1.error)))
    end
  end

  describe "snapshots" do
    test "get_snapshot returns not found for non-existent snapshot" do
      entity = ReplicationFactory.postgres_replication(id: Factory.uuid())
      assert {:error, %Error.NotFoundError{}} = Health.get_snapshot(entity)
    end

    test "upsert_snapshot creates new snapshot for replication slot" do
      entity = ReplicationFactory.postgres_replication(id: Factory.uuid(), inserted_at: DateTime.utc_now())

      # Set initial health
      :ok = Health.put_event(entity, %Event{slug: :replication_connected, status: :success})

      assert {:ok, snapshot} = Health.upsert_snapshot(entity)
      assert snapshot.entity_id == entity.id
      assert snapshot.entity_kind == :postgres_replication_slot
      assert snapshot.status == :initializing
      assert is_map(snapshot.health_json)
    end

    test "upsert_snapshot updates existing snapshot" do
      entity = ReplicationFactory.postgres_replication(id: Factory.uuid(), inserted_at: DateTime.utc_now())

      # Set initial health and create snapshot
      :ok = Health.put_event(entity, %Event{slug: :replication_connected, status: :success})
      {:ok, initial_snapshot} = Health.upsert_snapshot(entity)

      # Update health and snapshot
      :ok =
        Health.put_event(
          entity,
          %Event{slug: :replication_connected, status: :fail, error: ErrorFactory.service_error()}
        )

      {:ok, updated_snapshot} = Health.upsert_snapshot(entity)

      assert updated_snapshot.id == initial_snapshot.id
      assert updated_snapshot.status == :error
      assert DateTime.compare(updated_snapshot.sampled_at, initial_snapshot.sampled_at) in [:gt, :eq]
    end

    test "upsert_snapshot creates new snapshot for consumer" do
      entity = ConsumersFactory.sink_consumer(id: Factory.uuid(), inserted_at: DateTime.utc_now())

      # Set initial health
      :ok = Health.put_event(entity, %Event{slug: :messages_filtered, status: :success})

      assert {:ok, snapshot} = Health.upsert_snapshot(entity)
      assert snapshot.entity_id == entity.id
      assert snapshot.entity_kind == :sink_consumer
      assert snapshot.status == :waiting
      assert is_map(snapshot.health_json)
    end
  end

  describe "on_status_change/3" do
    setup do
      test_pid = self()

      Req.Test.expect(Sequin.Pagerduty, fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        send(test_pid, {:req, conn, Jason.decode!(body)})

        Req.Test.json(conn, %{status: "success"})
      end)

      :ok
    end

    test "alerts PagerDuty when database status changes to error" do
      entity =
        ReplicationFactory.postgres_replication(
          id: Factory.uuid(),
          account: AccountsFactory.account(),
          account_id: Factory.uuid(),
          postgres_database: DatabasesFactory.postgres_database(),
          inserted_at: DateTime.utc_now()
        )

      Health.on_status_change(entity, :healthy, :error)

      assert_receive {:req, conn, body}

      assert conn.method == "POST"
      assert conn.path_info == ["v2", "enqueue"]

      assert body["dedup_key"] == "replication_slot_health_#{entity.id}"
      assert body["event_action"] == "trigger"
    end

    test "alerts PagerDuty when consumer status changes to warning" do
      entity =
        ConsumersFactory.sink_consumer(
          id: Factory.uuid(),
          name: "test-consumer",
          account: AccountsFactory.account(),
          inserted_at: DateTime.utc_now()
        )

      Health.on_status_change(entity, :healthy, :warning)

      assert_receive {:req, conn, body}

      assert conn.path_info == ["v2", "enqueue"]
      assert body["dedup_key"] == "consumer_health_#{entity.id}"
      assert body["event_action"] == "trigger"
    end

    test "resolves PagerDuty alert when status changes to healthy" do
      entity =
        ReplicationFactory.postgres_replication(
          id: Factory.uuid(),
          account: AccountsFactory.account(),
          account_id: Factory.uuid(),
          inserted_at: DateTime.utc_now(),
          postgres_database: DatabasesFactory.postgres_database()
        )

      Health.on_status_change(entity, :error, :healthy)

      assert_receive {:req, conn, body}

      assert conn.path_info == ["v2", "enqueue"]
      assert body["dedup_key"] == "replication_slot_health_#{entity.id}"
      assert body["event_action"] == "resolve"
    end

    test "skips PagerDuty when entity has ignore_health annotation" do
      entity =
        ReplicationFactory.postgres_replication(
          id: Factory.uuid(),
          inserted_at: DateTime.utc_now(),
          postgres_database: DatabasesFactory.postgres_database(),
          annotations: %{"ignore_health" => true}
        )

      Req.Test.stub(Sequin.Pagerduty, fn _req ->
        raise "should not be called"
      end)

      Health.on_status_change(entity, :healthy, :error)
    end

    test "skips PagerDuty when account has ignore_health annotation" do
      entity =
        ReplicationFactory.postgres_replication(
          id: Factory.uuid(),
          inserted_at: DateTime.utc_now(),
          account_id: Factory.uuid(),
          account: AccountsFactory.account(annotations: %{"ignore_health" => true}),
          postgres_database: DatabasesFactory.postgres_database()
        )

      Req.Test.stub(Sequin.Pagerduty, fn _req ->
        raise "should not be called"
      end)

      Health.on_status_change(entity, :healthy, :error)
    end
  end

  describe "update_snapshots/0" do
    setup do
      test_pid = self()

      Req.Test.stub(Sequin.Pagerduty, fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        send(test_pid, {:req, conn, Jason.decode!(body)})

        Req.Test.json(conn, %{status: "success"})
      end)

      :ok
    end

    test "snapshots health for active entities" do
      # Create active entities with proper relationships
      db = DatabasesFactory.insert_postgres_database!(name: "test-db")

      slot =
        ReplicationFactory.insert_postgres_replication!(
          status: :active,
          postgres_database_id: db.id,
          account_id: db.account_id
        )

      consumer =
        ConsumersFactory.insert_sink_consumer!(
          status: :active,
          name: "test-consumer",
          replication_slot_id: slot.id,
          account_id: db.account_id
        )

      pipeline =
        ReplicationFactory.insert_wal_pipeline!(
          status: :active,
          name: "test-pipeline",
          replication_slot_id: slot.id,
          account_id: db.account_id
        )

      # Set some health states
      Health.put_event(slot, %Event{slug: :replication_connected, status: :success})
      Health.put_event(consumer, %Event{slug: :messages_filtered, status: :warning})
      Health.put_event(pipeline, %Event{slug: :messages_ingested, status: :fail, error: ErrorFactory.service_error()})

      # Run snapshot update
      :ok = Health.update_snapshots()

      # Verify snapshots were created with correct status
      assert {:ok, slot_snapshot} = Health.get_snapshot(slot)
      assert slot_snapshot.status == :initializing
      assert slot_snapshot.entity_kind == :postgres_replication_slot

      assert {:ok, consumer_snapshot} = Health.get_snapshot(consumer)
      assert consumer_snapshot.status == :warning
      assert consumer_snapshot.entity_kind == :sink_consumer

      assert {:ok, pipeline_snapshot} = Health.get_snapshot(pipeline)
      assert pipeline_snapshot.status == :error
      assert pipeline_snapshot.entity_kind == :wal_pipeline
    end

    test "skips inactive entities" do
      # Create database with inactive replication slot
      db = DatabasesFactory.insert_postgres_database!(name: "test-db")

      slot =
        ReplicationFactory.insert_postgres_replication!(
          # Disabled slot means no active replication
          status: :disabled,
          postgres_database_id: db.id,
          account_id: db.account_id
        )

      deleted_consumer =
        ConsumersFactory.insert_sink_consumer!(
          status: :disabled,
          name: "deleted-consumer",
          replication_slot_id: slot.id,
          account_id: db.account_id
        )

      # Set some health states
      Health.put_event(slot, %Event{slug: :replication_connected, status: :fail, error: ErrorFactory.service_error()})

      Health.put_event(deleted_consumer, %Event{
        slug: :messages_filtered,
        status: :fail,
        error: ErrorFactory.service_error()
      })

      # Run snapshot update
      :ok = Health.update_snapshots()

      # Verify no snapshots were created for inactive entities
      # No snapshot because slot is disabled
      assert {:error, _} = Health.get_snapshot(slot)
      # No snapshot because consumer is disabled
      assert {:error, _} = Health.get_snapshot(deleted_consumer)
    end

    test "updates existing snapshots" do
      # Create entity and initial snapshot with proper relationships
      db =
        DatabasesFactory.insert_postgres_database!(name: "test-db")

      slot =
        ReplicationFactory.insert_postgres_replication!(
          status: :active,
          postgres_database_id: db.id,
          account_id: db.account_id
        )

      consumer =
        ConsumersFactory.insert_sink_consumer!(
          status: :active,
          name: "test-consumer",
          replication_slot_id: slot.id,
          account_id: db.account_id
        )

      # Set initial health and create snapshot
      Health.put_event(consumer, %Event{slug: :messages_filtered, status: :success})
      {:ok, initial_snapshot} = Health.upsert_snapshot(consumer)

      # Change health status
      Health.put_event(consumer, %Event{slug: :messages_filtered, status: :fail, error: ErrorFactory.service_error()})

      # Run snapshot update
      :ok = Health.update_snapshots()

      # Verify snapshot was updated
      {:ok, updated_snapshot} = Health.get_snapshot(consumer)
      assert updated_snapshot.id == initial_snapshot.id
      assert updated_snapshot.status == :error
      assert DateTime.compare(updated_snapshot.sampled_at, initial_snapshot.sampled_at) in [:gt, :eq]

      # Assert that PagerDuty was called
      assert_receive {:req, _conn, _body}
    end
  end
end
