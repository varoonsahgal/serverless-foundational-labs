# Exercise 07: Decoupling Work with an Amazon SQS Queue

## Estimated Duration

~35 minutes

## Scenario / Business Context

At **Acme Retail**, the storefront website needs to feel **fast**. But when a
customer places an order, several slow things have to happen behind the scenes:
charge a card, reserve inventory, generate an invoice PDF, and email a receipt.
If the website waited for all of that to finish before showing "Order
confirmed," customers would stare at a spinner for several seconds — and if the
invoice service was temporarily down, the whole checkout would fail.

The fix is **decoupling**. Instead of doing the slow work inline, the storefront
just drops a small "please process this order" note into a **queue** and
immediately tells the customer "Order confirmed!" A separate worker picks notes
off the queue and processes them at its own pace. If the worker is slow or
briefly offline, the notes wait safely in the queue.

Your job in this exercise is to build that queue with **Amazon SQS**.

> **Amazon SQS (Simple Queue Service)** is a fully managed **message queue**. A
> producer puts messages in; a consumer pulls messages out, processes them, and
> deletes them. It acts as a durable **buffer** between parts of a system.

## Learning Objectives

By the end of this exercise you will be able to:

1. Create a **Standard** SQS queue and explain Standard vs FIFO (First-In-
   First-Out).
2. **Send** and **receive** messages using the console.
3. Explain the **visibility timeout** and why receiving a message does **not**
   delete it.
4. Explain **at-least-once delivery** and why Standard queues don't guarantee
   ordering.
5. Describe the purpose of a **dead-letter queue (DLQ)** and a **redrive
   policy**.

## AWS Services Used

- **Amazon SQS (Simple Queue Service)** — the managed message queue.

## Prerequisites

- An **AWS account** you can log into.
- An **IAM (Identity and Access Management) user** with permissions to use SQS.
  **Do not use the root user** — it has unrestricted access and should be
  reserved for account-level tasks only.
- You are working in the **us-east-1 (N. Virginia)** Region. Confirm this in the
  Region selector at the top-right of the console.
- (No email inbox is required for this exercise — SQS is polled from the
  console.)

---

## Step-by-Step Instructions

### Step 1 — Open the SQS console in the correct Region

1. Sign in to the **AWS Management Console** as your IAM user (not root).
2. Confirm the Region in the top-right corner is **N. Virginia** (`us-east-1`).
3. In the search bar, type **SQS** and click **Simple Queue Service**.

> **Why This Matters:** Like most AWS resources, SQS queues are **Region-scoped**
> and **account-scoped**. A queue in `us-east-1` is invisible from another
> Region.

### Step 2 — Create a Standard queue

1. Click **Create queue**.
2. For **Type**, select **Standard**.
3. For **Name**, enter:

   ```
   acme-order-queue
   ```

**Standard vs FIFO:**

- **Standard** — nearly unlimited throughput, **at-least-once** delivery (a
  message may occasionally be delivered more than once), and **best-effort
  ordering** (messages usually arrive in order but not guaranteed). Great for
  work that is **idempotent** (safe to process more than once) and doesn't need
  strict order.
- **FIFO (First-In-First-Out)** — guarantees **exactly-once** processing and
  **strict ordering**, at lower throughput. FIFO queue names must end in
  `.fifo`. Use it only when order and no-duplicates truly matter (for example,
  processing account transactions in sequence).

### Step 3 — Understand the key configuration settings

Before creating, look at the **Configuration** section. Leave these at their
defaults for now, but understand what they do:

- **Visibility timeout — default 30 seconds.** When a consumer receives a
  message, SQS **hides** it from other consumers for this many seconds so two
  workers don't process the same message at once. If the consumer finishes and
  **deletes** the message before the timer expires, it's gone for good. If the
  consumer does **not** delete it in time (e.g., it crashed), the message becomes
  **visible again** and can be received by another consumer. This is what makes
  SQS resilient.
- **Message retention period — default 4 days.** How long an **undelivered/
  undeleted** message stays in the queue before SQS discards it. Can be set from
  1 minute to 14 days.
- **Delivery delay — default 0 seconds.** How long to hide a **newly sent**
  message before it becomes available to receive. Useful to postpone processing.
- **Receive message wait time — default 0 seconds (short polling).** Controls
  polling behavior:
  - **Short polling (0s):** a receive request returns immediately, even if it
    checks only a subset of servers and finds nothing — can return empty even
    when messages exist.
  - **Long polling (1–20s):** a receive request waits up to this many seconds for
    a message to arrive before returning. Long polling reduces empty responses
    and **lowers cost** (fewer API calls). In production, setting this to `20` is
    a best practice.

4. Scroll to the bottom and click **Create queue**.

> **AWS Mental Model:** Think of an SQS queue as a **shared to-do list** taped to
> the wall between two teams. The storefront team keeps adding sticky notes
> ("process order #A-10427"). A worker grabs a note, does the task, and throws
> the note away. If the worker is busy, the notes just wait. Unlike SNS's
> megaphone (one announcement heard by everyone), an SQS note is meant to be
> handled by **exactly one** worker.

**Validation:** After creation you land on the queue's detail page. Note two
identifiers near the top:

- **URL** — e.g. `https://sqs.us-east-1.amazonaws.com/123456789012/acme-order-queue`.
  This is the address you **send to and receive from** (used by the SDK/CLI).
- **ARN (Amazon Resource Name)** — e.g.
  `arn:aws:sqs:us-east-1:123456789012:acme-order-queue`. This is the queue's
  unique **identity**, used in **IAM policies** and when wiring the queue to
  other services.

> **Common Beginner Mistake:** Confusing the **queue URL** (where you send/
> receive) with the **queue ARN** (the identity used in permissions and service
> integrations). If a policy or event source asks for an ARN, giving it the URL
> won't work, and vice versa.

### Step 4 — Send messages to the queue

You'll play the storefront and drop a few order-processing notes into the queue.

1. On the queue page, click **Send and receive messages**.
2. In the **Message body** box, enter a JSON payload:

   ```json
   {"orderId": "A-10427", "task": "process-order", "amount": 42.50}
   ```

3. Click **Send message**.
4. Repeat for two more messages so you have a few to work with:

   ```json
   {"orderId": "A-10428", "task": "process-order", "amount": 18.00}
   ```

   ```json
   {"orderId": "A-10429", "task": "process-order", "amount": 99.99}
   ```

**Validation:** Each send shows a green success banner with a **Message ID**. Go
back to the queue list (or the **Monitoring** tab) — the metric
**ApproximateNumberOfMessages** should read **3** (it may take a few seconds and
a refresh to update). "Approximate" because SQS is a massively distributed
system and the count is eventually consistent.

### Step 5 — Receive (poll for) messages

Now play the worker and pull notes off the list.

1. Still on the **Send and receive messages** page, scroll to the **Receive
   messages** section.
2. Click **Poll for messages**.
3. Within a few seconds, your messages appear in the list, each showing its
   **Message ID**, **Sent** time, and a **Receive count**.
4. Click a message to expand and read its **Body** — you'll see the JSON you
   sent.

> **What Is Happening Behind the Scenes?** The instant you polled, SQS marked
> those messages as **in flight** and started their **visibility timeout** (30s).
> During that window they are **hidden** from any other poller so no one else
> grabs the same work. Watch the console: if you wait past ~30 seconds and click
> **Poll for messages** again, the same messages reappear and their **Receive
> count** increases — because you received them but never **deleted** them, so
> SQS assumed processing failed and made them visible again.

> **Common Beginner Mistake:** Assuming that **receiving a message deletes it.**
> It does **not.** Receiving only *hides* the message for the visibility timeout.
> A consumer must **explicitly delete** the message after successfully processing
> it. Forgetting to delete means the same message gets processed over and over.

### Step 6 — Delete a processed message

1. In the **Receive messages** list, select the checkbox next to one message.
2. Click **Delete**.
3. Confirm the deletion.

**Validation:** After the visibility timeout passes, click **Poll for messages**
again. The deleted message does **not** come back, while the messages you did
*not* delete **do** reappear. On the **Monitoring** tab,
**ApproximateNumberOfMessages** decreases as you delete messages.

> **AWS Mental Model — pull vs push:** SNS (Exercise 06) **pushes** — it actively
> delivers to every subscriber. SQS **pulls** — nothing happens until a consumer
> asks "any work for me?" This pull model is what lets a slow or offline worker
> avoid being overwhelmed: messages simply wait until it's ready.

> **Common Beginner Mistake:** Expecting **strict ordering** from a **Standard**
> queue. Standard queues are best-effort order and at-least-once. If your
> processing genuinely depends on order or must never see duplicates, you need a
> **FIFO** queue — or you design your worker to be **idempotent** (processing the
> same order twice produces the same result).

> **Cost Awareness:** SQS is billed **per request** (each send, receive, and
> delete is an API call), and the **first 1 million requests per month are
> free**. This entire exercise costs effectively nothing. Long polling reduces
> request count and therefore cost. Still, **delete the queue when you're done**
> (see Cleanup).

> **Security Consideration:** Each queue has a **queue access policy** (a JSON
> resource policy) that controls **who can send to and receive from** it. By
> default only your account has access. When you later connect an SNS topic or
> another AWS service to the queue, you grant that specific principal permission
> in the queue policy rather than sharing credentials.

> **Assessment Connection:** Know the decision signal. Choose **SQS** when the
> scenario says "**decouple**, buffer bursts, process work asynchronously, one
> worker per item, retry failed work." Choose **SNS** when it says "**notify /
> broadcast / fan-out to many recipients.**" A frequent pattern combines both:
> **SNS fans out to multiple SQS queues**, each drained by its own worker.

---

## Concept Recap: Key Terms

- **Queue URL vs ARN** — the **URL** is the send/receive endpoint; the **ARN
  (Amazon Resource Name)** is the identity used in IAM policies and service
  integrations.
- **At-least-once delivery** — Standard SQS guarantees a message is delivered
  *at least* once, occasionally more than once; design consumers to be
  **idempotent**.
- **Visibility timeout** — the window during which a received (in-flight)
  message is hidden from other consumers. Delete before it expires, or the
  message returns.
- **Dead-letter queue (DLQ)** — a separate queue that automatically collects
  messages that fail processing too many times (see the challenge).

## Key Takeaways

1. **SQS decouples** producers from consumers with a durable buffer, so slow or
   offline workers don't break the front end.
2. **Receiving ≠ deleting.** A received message is only *hidden* for the
   visibility timeout; you must **explicitly delete** it after processing.
3. **Standard = at-least-once, best-effort order.** Make consumers idempotent, or
   use **FIFO** when order/no-duplicates is essential.
4. **Long polling** (Receive message wait time 1–20s) reduces empty responses and
   cost versus short polling.
5. **Queue URL** is for send/receive; **queue ARN** is for identity/permissions.
6. A **DLQ** with a **redrive policy** captures repeatedly failing messages so
   they don't clog the main queue.

## Cleanup Instructions

1. In the SQS console, go to **Queues**.
2. Select `acme-order-queue`.
3. Click **Delete**.
4. Type `delete` in the confirmation box and confirm.
5. If you created a dead-letter queue in the challenge (`acme-order-dlq`), select
   it and **Delete** it too.

**Validation:** The **Queues** list no longer shows `acme-order-queue` (or
`acme-order-dlq`).

---

## Early-Finisher Challenge

Acme wants to make sure that a "poison" order — one that keeps failing to
process — doesn't get retried forever and clog the main queue. Build a **safety
net** using a **dead-letter queue (DLQ)**.

**Your task:**

1. Create a second queue named `acme-order-dlq`.
2. Configure the **main** queue (`acme-order-queue`) with a **redrive policy**
   that sends a message to the DLQ after it has been received **3 times** without
   being deleted (`maxReceiveCount = 3`).
3. Demonstrate a message moving to the DLQ by receiving it repeatedly (without
   deleting) until it lands in `acme-order-dlq`.

---

## Challenge Solution

### 1. Create the dead-letter queue

1. In the SQS console, click **Create queue**.
2. **Type:** Standard.
3. **Name:** `acme-order-dlq`.
4. Leave defaults and click **Create queue**.
5. On its detail page, copy its **ARN** (you'll reference it by name in the next
   step) — e.g. `arn:aws:sqs:us-east-1:123456789012:acme-order-dlq`.

> **AWS Mental Model:** A **DLQ** is the "problem pile." Any note the worker keeps
> fumbling gets moved out of the main to-do list and set aside so a human can
> inspect it later — without blocking the healthy work.

### 2. Attach a redrive policy to the main queue

1. Go to **Queues** and open `acme-order-queue`.
2. Click **Edit**.
3. Scroll to **Dead-letter queue** and toggle it to **Enabled**.
4. For **Choose queue**, select `acme-order-dlq` (or paste its ARN).
5. Set **Maximum receives** to:

   ```
   3
   ```

   This is the `maxReceiveCount`: after a message is received **3** times
   without being deleted, SQS moves it to the DLQ on the next receive.
6. Click **Save**.

> **What Is Happening Behind the Scenes?** SQS tracks a **Receive count** on each
> message. Every time a message is received, that counter increments. When the
> count **exceeds** `maxReceiveCount`, SQS automatically **redrives** the message
> to the configured DLQ instead of making it visible in the main queue again.
> This turns "keeps failing" into "gets quarantined."

### 3. Send a test message

1. Open `acme-order-queue` → **Send and receive messages**.
2. Send one message body:

   ```json
   {"orderId": "A-99999", "task": "process-order", "note": "poison message"}
   ```

### 4. Receive it repeatedly WITHOUT deleting

Simulate a worker that keeps failing to process the message:

1. In the **Receive messages** section, click **Poll for messages** — the message
   appears with **Receive count = 1**. **Do not delete it.**
2. Stop polling and wait for the **visibility timeout** (30s) to pass so the
   message becomes visible again.
3. Click **Poll for messages** again — **Receive count = 2**. Do not delete.
4. Wait for the visibility timeout again, then **Poll for messages** — **Receive
   count = 3**. Do not delete.
5. Wait one more visibility-timeout cycle and **Poll for messages** once more. The
   message is now **gone from the main queue** — it exceeded `maxReceiveCount`
   and was redriven to the DLQ.

> **Tip:** To make this faster, you can temporarily lower the main queue's
> **Visibility timeout** to a few seconds (Edit → Visibility timeout) so you don't
> wait 30 seconds between polls. Set it back if you keep using the queue.

### 5. Validate the message is in the DLQ

1. Go to **Queues** and open `acme-order-dlq`.
2. Click **Send and receive messages** → **Poll for messages**.
3. The `A-99999` "poison message" now appears here.
4. Check the **Monitoring** tab of each queue:
   - `acme-order-queue` → **ApproximateNumberOfMessages = 0**
   - `acme-order-dlq` → **ApproximateNumberOfMessages = 1**

**Expected result:** The problematic message has been automatically quarantined
in the DLQ after 3 failed receive attempts, while the main queue stays clear for
healthy work.

### 6. Cleanup

Follow the **Cleanup Instructions** above: delete `acme-order-queue`, then delete
`acme-order-dlq`.
