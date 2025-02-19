<script lang="ts">
  import { onMount } from "svelte";
  import {
    ArrowLeft,
    Clock,
    RotateCw,
    CirclePlay,
    Webhook,
    AlertCircle,
    Pause,
  } from "lucide-svelte";
  import { Button } from "$lib/components/ui/button";
  import * as Dialog from "$lib/components/ui/dialog";
  import { formatRelativeTimestamp } from "../utils";
  import LinkPushNavigate from "$lib/components/LinkPushNavigate.svelte";
  import SQSIcon from "../../icons/sqs.svelte";
  import RedisIcon from "../../icons/redis.svelte";
  import KafkaIcon from "../../icons/kafka.svelte";
  import GcpPubsubIcon from "../../icons/gcp_pubsub.svelte";
  import SequinStreamIcon from "../../icons/sequin_stream.svelte";
  import NatsIcon from "../../icons/nats.svelte";
  import RabbitMqIcon from "../../icons/rabbitmq.svelte";

  export let consumer;
  export let consumerTitle;
  export let live_action;
  export let live;
  export let parent;
  export let messages_failing;

  let showDeleteConfirmDialog = false;
  let showPauseConfirmDialog = false;
  let deleteConfirmDialogLoading = false;

  let statusTransitioning = false;
  let statusTransitionTimeout: NodeJS.Timeout | null = null;
  let displayStatus = consumer.status;

  $: {
    if (!statusTransitioning) {
      displayStatus = consumer.status;
    }
  }

  function handleStatusTransition() {
    if (statusTransitionTimeout) {
      clearTimeout(statusTransitionTimeout);
    }

    statusTransitionTimeout = setTimeout(() => {
      statusTransitioning = false;
      statusTransitionTimeout = null;
    }, 2000);
  }

  function handleEdit() {
    live.pushEventTo("#" + parent, "edit", {});
  }

  function handleDelete() {
    showDeleteConfirmDialog = true;
  }

  function cancelDelete() {
    showDeleteConfirmDialog = false;
  }

  function confirmDelete() {
    deleteConfirmDialogLoading = true;
    live.pushEventTo("#" + parent, "delete", {}, () => {
      showDeleteConfirmDialog = false;
      deleteConfirmDialogLoading = false;
    });
  }

  function confirmPause() {
    displayStatus = "disabled";
    statusTransitioning = true;
    live.pushEventTo("#" + parent, "disable", {}, () => {
      showPauseConfirmDialog = false;
      handleStatusTransition();
    });
  }

  function enableConsumer() {
    displayStatus = "active";
    statusTransitioning = true;
    live.pushEventTo("#" + parent, "enable", {}, () => {
      handleStatusTransition();
    });
  }

  let activeTab: string;

  $: messageUrl = messages_failing
    ? `${consumer.href}/messages?showAcked=false`
    : `${consumer.href}/messages`;

  onMount(() => {
    activeTab = live_action === "messages" ? "messages" : "overview";
  });
</script>

<div class="bg-white border-b header">
  <div class="container mx-auto px-4 py-4">
    <div class="flex items-center justify-between">
      <div class="flex items-center space-x-4">
        <LinkPushNavigate href="/sinks">
          <Button variant="ghost" size="sm">
            <ArrowLeft class="h-4 w-4" />
          </Button>
        </LinkPushNavigate>
        <div class="grid grid-cols-[auto_1fr]">
          <span></span>
          <span class="text-xs text-gray-500">{consumerTitle}</span>
          {#if consumer.sink.type === "http_push"}
            <Webhook class="h-6 w-6 mr-2" />
          {:else if consumer.sink.type === "sqs"}
            <SQSIcon class="h-6 w-6 mr-2" />
          {:else if consumer.sink.type === "redis"}
            <RedisIcon class="h-6 w-6 mr-2" />
          {:else if consumer.sink.type === "kafka"}
            <KafkaIcon class="h-6 w-6 mr-2" />
          {:else if consumer.sink.type === "gcp_pubsub"}
            <GcpPubsubIcon class="h-6 w-6 mr-2" />
          {:else if consumer.sink.type === "sequin_stream"}
            <SequinStreamIcon class="h-6 w-6 mr-2" />
          {:else if consumer.sink.type === "nats"}
            <NatsIcon class="h-6 w-6 mr-2" />
          {:else if consumer.sink.type === "rabbitmq"}
            <RabbitMqIcon class="h-6 w-6 mr-2" />
          {/if}
          <h1 class="text-xl font-semibold">
            {consumer.name}
          </h1>
        </div>
      </div>
      <div class="flex items-center space-x-4">
        <div
          class="hidden lg:flex flex-col items-left gap-1 text-xs text-gray-500"
        >
          <div class="flex items-center gap-2">
            <Clock class="h-4 w-4" />
            <span>Created {formatRelativeTimestamp(consumer.inserted_at)}</span>
          </div>
          <div class="flex items-center gap-2">
            <RotateCw class="h-4 w-4" />
            <span>Updated {formatRelativeTimestamp(consumer.updated_at)}</span>
          </div>
        </div>
        {#if consumer.sink.type !== "sequin_stream"}
          {#if statusTransitioning}
            {#if displayStatus === "active"}
              <Button variant="outline" size="sm" disabled>
                <CirclePlay class="h-4 w-4 mr-1" />
                Resuming...
              </Button>
            {:else}
              <Button variant="outline" size="sm" disabled>
                <Pause class="h-4 w-4 mr-1" />
                Pausing...
              </Button>
            {/if}
          {:else if displayStatus === "active"}
            <Button
              variant="outline"
              size="sm"
              on:click={() => (showPauseConfirmDialog = true)}
            >
              <Pause class="h-4 w-4 mr-1" />
              Pause
            </Button>
          {:else}
            <Button variant="outline" size="sm" on:click={enableConsumer}>
              <CirclePlay class="h-4 w-4 mr-1" />
              Resume
            </Button>
          {/if}
        {/if}
        <Button variant="outline" size="sm" on:click={handleEdit}>Edit</Button>
        <Button
          variant="outline"
          size="sm"
          class="text-red-600 hover:text-red-700"
          on:click={handleDelete}
        >
          Delete
        </Button>
      </div>
    </div>
  </div>

  <div class="container mx-auto px-4">
    <div class="flex space-x-4">
      <a
        href={consumer.href}
        class={`py-2 px-4 font-medium border-b-2 ${
          activeTab === "overview"
            ? "text-black border-black"
            : "text-gray-500 hover:text-gray-700 border-transparent"
        }`}
        data-phx-link="redirect"
        data-phx-link-state="push"
      >
        Overview
      </a>
      <a
        href={messageUrl}
        class={`py-2 px-4 flex items-center font-medium border-b-2 ${
          activeTab === "messages"
            ? "text-black border-black"
            : "text-gray-500 hover:text-gray-700 border-transparent"
        }`}
        data-phx-link="redirect"
        data-phx-link-state="push"
      >
        Messages
        {#if messages_failing}
          <AlertCircle class="h-4 w-4 text-red-600 ml-1" />
        {/if}
      </a>
    </div>
  </div>
</div>

<Dialog.Root bind:open={showDeleteConfirmDialog}>
  <Dialog.Content>
    <Dialog.Header>
      <Dialog.Title class="leading-6">
        Are you sure you want to delete this {consumerTitle}?
      </Dialog.Title>
      <Dialog.Description>This action cannot be undone.</Dialog.Description>
    </Dialog.Header>
    <Dialog.Footer>
      <Button variant="outline" on:click={cancelDelete}>Cancel</Button>
      <Button
        variant="destructive"
        on:click={confirmDelete}
        disabled={deleteConfirmDialogLoading}
      >
        {#if deleteConfirmDialogLoading}
          Deleting...
        {:else}
          Delete
        {/if}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>

<Dialog.Root bind:open={showPauseConfirmDialog}>
  <Dialog.Content>
    <Dialog.Header>
      <Dialog.Title class="leading-6">Pause {consumerTitle}?</Dialog.Title>
      <Dialog.Description class="mb-6">
        The sink will stop receiving new messages until resumed.
      </Dialog.Description>
    </Dialog.Header>
    <Dialog.Footer class="mt-4">
      <Button
        variant="outline"
        on:click={() => (showPauseConfirmDialog = false)}>Cancel</Button
      >
      <Button
        variant="secondary"
        on:click={confirmPause}
        disabled={statusTransitioning}
      >
        {#if statusTransitioning}
          Pausing...
        {:else}
          Pause
        {/if}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
