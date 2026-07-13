# Lab 07: Decoupling Work with Amazon SQS — The Acme Retail Order Pipeline

## Estimated Duration

~90 minutes

## Scenario / Business Context

**Acme Retail** has a serious Black Friday problem. When 10,000 customers hit "Place Order" simultaneously, the checkout service crashes — not because it can't handle the traffic, but because it waits synchronously for five downstream services (inventory reservation, payment processing, invoice generation, warehouse notification, and email confirmation) before returning a response. The slowest of these — invoice generation — takes up to 8 seconds. At peak traffic, customers time out and abandon their carts.

The engineering team has decided to **decouple** the checkout service from all downstream processing using **Amazon SQS (Simple Queue Service)**. The new architecture works like this:

```
Customer Browser
      |
      v
 Checkout API  ----> acme-order-validation-queue  ----> Validation Worker (Lambda)
                                                              |
                                                              v
                                              acme-fulfillment-queue  ----> Fulfillment Worker (Lambda)
                                                              |
                                                              v
                                              acme-notification-queue  ----> Notification Worker (Lambda)
                                                              |
                                             (failed messages after 3 attempts)
                                                              v
                                              acme-order-dlq  ----> DLQ Monitor (Lambda)
```

Instead of waiting for all downstream work to complete, the checkout API drops a small JSON message into a queue and immediately returns "Order accepted!" to the customer. Each downstream service picks up messages from its own queue at its own pace. If the invoice service goes down for 10 minutes, orders simply queue up and are processed when it recovers — no data lost, no customer impact beyond a slight delay.

Your job in this lab is to build this queuing infrastructure and learn SQS deeply: queue types, message lifecycle, visibility timeouts, dead-letter queues, Lambda integration, and security.

> **AWS Mental Model:** Think of SQS as a **durable to-do list** shared between two teams. The checkout team posts sticky notes ("process order #A-10427"). A worker picks up a note, handles the task, and discards the note. If the worker is overwhelmed, notes just pile up harmlessly — the sticky-note wall never crashes. Unlike a direct API call, the sender doesn't wait and doesn't need to know who (or how many workers) will handle the note.

## Learning Objectives

By the end of this lab you will be able to:

1. Create and configure **Standard** and **FIFO** SQS queues and explain when to use each.
2. Explain the **message lifecycle**: send → receive → in-flight → delete (or become visible again).
3. Explain **visibility timeout** and what happens when it expires.
4. Configure a **Dead-Letter Queue (DLQ)** with a redrive policy and explain the "poison message" problem it solves.
5. Configure **SQS as an event source for AWS Lambda** (event source mapping).
6. Use **SQS message attributes** to add metadata to messages.
7. Explain **long polling vs. short polling** and the cost difference.
8. Implement basic **SQS security**: SSE-SQS encryption, queue access policies.
9. Read **CloudWatch metrics** for SQS queues.
10. Explain the SQS Extended Client pattern for large payloads.

## AWS Services Used

- **Amazon SQS** — the managed message queue
- **AWS Lambda** — the worker functions that consume messages
- **Amazon CloudWatch** — metrics and monitoring for your queues
- **AWS IAM** — execution roles and queue access policies
- **Amazon S3** — discussed conceptually for the Extended Client pattern

## Prerequisites

- An AWS account you can log into.
- An IAM user (not root) with permissions for SQS, Lambda, IAM, and CloudWatch.
- You are working in **US West (Oregon) `us-west-2`**. Confirm this in the Region selector at the top-right of the console before starting every step.

> **Why us-west-2?** Acme Retail's primary infrastructure runs in US West (Oregon). Keeping all resources in the same region avoids cross-region data transfer costs and latency. When you build real systems, co-locate resources that talk to each other.


> **Shared Account — Use Your Initials on Every Resource:** You are working in a **shared AWS account** alongside other students. To avoid naming conflicts, **append your initials to every resource you create** in this lab. For example, if your name is Jane Smith use the suffix `-js` (lowercase) or `-JS` (uppercase) consistently.
>
> | Default name in instructions | What you should actually create |
> |---|---|
> | `acme-order-processor` | `acme-order-processor-js` |
> | `AcmeProducts` | `AcmeProducts-JS` |
> | `AcmeLambdaExecRole` | `AcmeLambdaExecRole-JS` |
>
> This applies to **all** Lambda functions, DynamoDB tables, IAM roles, IAM policies, Cognito User Pools, SNS topics, SQS queues, Step Functions state machines, API Gateway APIs, CodePipeline pipelines, CloudWatch dashboards, S3 buckets, and any other named AWS resource. Wherever the instructions say to type a resource name, add your initials. Skip initials only for things you are not creating (e.g., selecting an existing AWS managed policy like `AmazonDynamoDBReadOnlyAccess`).

---

## Part 1: Understanding SQS Queue Types

Before creating any queues, understand the two fundamental queue types. Choosing the wrong type is a common architectural mistake.

### Standard vs. FIFO — The Decision Table

| Feature | Standard Queue | FIFO Queue |
|---|---|---|
| **Throughput** | Nearly unlimited (3,000 msg/sec with batching) | Up to 3,000 msg/sec with batching |
| **Ordering** | Best-effort (usually in order, not guaranteed) | Strict FIFO within a message group |
| **Delivery** | At-least-once (rare duplicates possible) | Exactly-once (within deduplication window) |
| **Name suffix** | None required | Must end in `.fifo` |
| **Use case** | Idempotent work queues, high-throughput pipelines | Financial transactions, ordering systems, inventory updates |
| **Price** | Lower per million requests | Higher per million requests |

> **AWS Mental Model:** Standard queues are like a postal bin in a mail room — letters usually come out in order, but occasionally two are switched, and rarely the same letter appears twice. FIFO queues are like a numbered ticket system — every ticket is processed exactly once in the exact order issued. Use FIFO when duplicates or out-of-order processing would cause real business harm (e.g., debiting an account twice).

> **Common Beginner Mistake:** Defaulting to FIFO "just to be safe" when your consumer is already idempotent. FIFO costs more, has lower throughput, and requires extra configuration (MessageGroupId, deduplication). Start with Standard unless you have a concrete reason for strict ordering.

---

## Part 2: Create the Order Processing Queues

### Step 1 — Open the SQS console in us-west-2

1. Sign in to the **AWS Management Console** as your IAM user (not root).
2. Confirm the Region in the top-right corner is **US West (Oregon)** (`us-west-2`). If it shows any other region, click the region name and select **US West (Oregon)**.
3. In the search bar, type **SQS** and click **Simple Queue Service**.

> **Why This Matters:** SQS queues are **Region-scoped**. A queue created in `us-west-2` is completely invisible from any other Region. All resources in this lab must be in the same region.

### Step 2 — Create the Dead-Letter Queue first

Always create your DLQ **before** the main queues so you can reference it during main queue creation.

1. Click **Create queue**.
2. **Type:** select **Standard**.
3. **Name:** enter `acme-order-dlq`.
4. Under **Configuration**, set:
   - **Visibility timeout:** `60` seconds (give the DLQ processor enough time to alert)
   - **Message retention period:** `14 days` (keep failed messages long enough to diagnose)
   - **Receive message wait time:** `20` seconds (long polling — see Part 3)
5. Scroll to **Encryption** and select **Server-side encryption: Enabled — SQS-managed encryption keys (SSE-SQS)**.

> **Security Consideration:** SSE-SQS encrypts messages at rest using AWS-managed keys at no additional cost. This is a zero-friction security best practice — enable it on every queue in production. For stricter control (audit trails, key rotation schedules), use **SSE-KMS** with a customer-managed key instead.

6. Leave **Access policy** at **Basic** (only the queue owner can send/receive).
7. Click **Create queue**.

**Validation:** You land on the DLQ detail page. Copy the **Queue ARN** (it looks like `arn:aws:sqs:us-west-2:123456789012:acme-order-dlq`) — you will need it in the next step.

### Step 3 — Create the main Validation Queue with a DLQ redrive policy

1. Click **Create queue** (or go back to the **Queues** list and click **Create queue**).
2. **Type:** **Standard**.
3. **Name:** `acme-order-validation-queue`.
4. Under **Configuration**, set:
   - **Visibility timeout:** `30` seconds
   - **Message retention period:** `4 days`
   - **Maximum message size:** `256 KB` (default)
   - **Delivery delay:** `0` seconds (no delay — process immediately)
   - **Receive message wait time:** `20` seconds (long polling enabled)

> **Deep Dive — Visibility Timeout:** When a consumer calls `ReceiveMessage`, SQS marks the message as **in-flight** and starts a countdown (the visibility timeout). During this window, **no other consumer can see or receive the message**. This prevents two workers from processing the same order simultaneously. The consumer has until the timer expires to: (1) process the message and (2) call `DeleteMessage`. If the timer expires before deletion — because the worker crashed or took too long — SQS makes the message **visible again**, and it gets picked up by another worker. This is what gives SQS its resilience: work is never truly lost, just retried.

5. Enable **SSE-SQS** encryption (same as the DLQ).
6. Scroll to **Dead-letter queue** → click **Enabled**.
7. In the **Choose queue** dropdown, select **acme-order-dlq**.
8. Set **Maximum receives** to `3`.

> **The Poison Message Problem:** Imagine order `#A-99999` is malformed JSON that crashes your worker every time it runs. Without a DLQ, this message gets retried indefinitely — the worker crashes, the message becomes visible again, another worker grabs it, crashes, repeat forever. This "poison message" blocks the queue and wastes compute. With a DLQ and `maxReceiveCount=3`, after the third failed receive SQS automatically **redrive**s the message to `acme-order-dlq`. Your main queue is unblocked. A separate DLQ monitor processes the failure, alerts the team, and the bad order is investigated.

9. Click **Create queue**.

**Validation:** On the queue detail page, under **Dead-letter queue**, confirm it shows `acme-order-dlq` with **Maximum receives: 3**.

### Step 4 — Create the Fulfillment and Notification Queues

Repeat the same process (Standard, SSE-SQS enabled, DLQ = acme-order-dlq, maxReceiveCount = 3, long polling = 20s) for:

- `acme-fulfillment-queue` — visibility timeout `60` seconds (fulfillment takes longer)
- `acme-notification-queue` — visibility timeout `15` seconds (notifications are fast)

**Validation:** You should now have 4 queues in the console:
- `acme-order-dlq`
- `acme-order-validation-queue`
- `acme-fulfillment-queue`
- `acme-notification-queue`

---

## Part 3: The Message Lifecycle — Send, Receive, Delete

### Step 5 — Understanding Long Polling vs. Short Polling

Before sending messages, understand the polling modes — this decision affects both cost and latency.

| | Short Polling | Long Polling |
|---|---|---|
| **Receive message wait time setting** | 0 seconds | 1–20 seconds |
| **Behavior** | Returns immediately (even empty) | Waits up to N seconds for a message |
| **Empty responses** | Common — many empty API calls | Rare — only returns when messages arrive or timeout |
| **Cost** | Higher (more API calls) | Lower (fewer calls, same work) |
| **Latency** | Very low per call | Slightly higher per call, much lower empty overhead |
| **Recommendation** | Only for strict latency requirements | **Production default** (set to 20 seconds) |

> **Cost Awareness:** SQS charges per API request. Short polling with an active consumer makes one API call every few milliseconds, even when the queue is empty — generating millions of requests per day. Long polling reduces this by 99%+ for low-traffic queues. The first million SQS requests per month are free, but setting long polling from the start is a best practice that saves money as you scale.

### Step 6 — Send messages with custom attributes

SQS message **attributes** let you attach metadata to a message without putting it in the message body. This is useful for routing decisions and filtering without deserializing the body.

1. In the SQS console, click **acme-order-validation-queue**.
2. Click **Send and receive messages**.
3. In the **Message body** box, paste:

```json
{
  "orderId": "A-10427",
  "customerId": "C-5512",
  "items": [
    {"sku": "SHOE-001", "qty": 1, "price": 89.99},
    {"sku": "SHIRT-042", "qty": 2, "price": 34.50}
  ],
  "totalAmount": 158.99,
  "orderTimestamp": "2026-07-12T09:15:00Z"
}
```

4. Scroll down to **Message attributes**. Click **Add attribute** three times to add:

   | Attribute name | Attribute type | Value |
   |---|---|---|
   | `OrderId` | String | `A-10427` |
   | `Priority` | String | `STANDARD` |
   | `OrderType` | String | `WEB` |

> **Why Message Attributes?** Attributes let a consumer decide whether to process a message (or route it differently) without parsing the full JSON body. A VIP order processor might check the `Priority` attribute first and skip non-VIP messages. The body can be 256 KB; attributes let you make fast routing decisions on lightweight metadata. Note: SQS does NOT support native filtering like SNS — you filter in your consumer code, not at the queue level.

5. Click **Send message**. Note the **Message ID** in the success banner.
6. Send two more messages for orders `A-10428` and `A-10429` with similar structure but different amounts.

**Validation:** After sending 3 messages, go to the queue's **Monitoring** tab. The **ApproximateNumberOfMessagesVisible** metric should show `3` (may take 30–60 seconds to update due to eventual consistency).

### Step 7 — Receive messages and observe visibility timeout in action

1. Still on the **Send and receive messages** page, scroll to **Receive messages**.
2. Click **Poll for messages**.
3. Three messages appear in the list. Note each message's **Receive count** (should be `1`).
4. Click any message to expand it. Check:
   - **Body** — the JSON you sent
   - **Attributes** tab — your `OrderId`, `Priority`, and `OrderType` attributes are shown separately from the body

> **What Is Happening Behind the Scenes?** The moment you clicked "Poll for messages," SQS marked these messages **in-flight** and started their 30-second visibility timeout countdown. They are now invisible to any other consumer. Notice you haven't deleted them yet — SQS has not assumed processing succeeded.

5. **Wait 35 seconds** (past the visibility timeout). Then click **Poll for messages** again.

**Validation:** The same messages reappear, but their **Receive count** is now `2`. SQS re-delivered them because you never called DeleteMessage. This demonstrates at-least-once delivery — in production your code must handle this case (idempotency).

### Step 8 — Delete a processed message

1. Select the checkbox next to one message.
2. Click **Delete**. Confirm.

**Validation:** After polling again, that message does not reappear. The other two still come back (receive count 3). Leave them — they will demonstrate the DLQ redrive in the next step.

---

## Part 4: Dead-Letter Queue in Action

### Step 9 — Trigger the DLQ redrive

The two remaining messages have now been received 3 times without deletion. SQS should automatically redrive them to `acme-order-dlq`.

> **How the Redrive Works:** SQS checks the receive count each time a message is received. When `receiveCount >= maxReceiveCount` (which you set to 3), the next time the visibility timeout expires, SQS moves the message to the DLQ instead of making it visible again in the source queue. The message is not moved immediately when you receive it for the 3rd time — it moves after that visibility timeout expires.

1. Click **Poll for messages** one more time. The messages appear (receive count = 3).
2. **Do NOT delete them.** Wait 35 seconds for the visibility timeout to expire.
3. Navigate to **acme-order-dlq** and click **Send and receive messages** → **Poll for messages**.

**Validation:** Your two "poison" messages appear in the DLQ. Their receive count starts at 1 again (because this is a new receive from a new queue). Go back to `acme-order-validation-queue` and poll — it is now empty.

> **AWS Mental Model:** The DLQ is a quarantine ward. Sick messages (those that keep failing) are automatically isolated so they stop infecting healthy queue workers. Your DLQ monitor can then alert the on-call team, who inspects the messages, fixes the root cause, and re-queues them when ready.

---

## Part 5: Lambda Event Source Mapping — Automating Queue Processing

So far you have been manually polling the queue. In production, Lambda automatically polls your queue and invokes your function when messages arrive. This is called an **event source mapping**.

### Step 10 — Create the order validation Lambda function

1. Navigate to **Lambda**. Confirm region is **us-west-2**.
2. Click **Create function** → **Author from scratch**.
3. **Function name:** `acme-order-validator`
4. **Runtime:** **Python 3.12**
5. **Architecture:** `x86_64`
6. Leave **Create a new role with basic Lambda permissions** selected.
7. Click **Create function**.
8. Replace the code in `lambda_function.py` with:

```python
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    """
    SQS event source mapping delivers a batch of records.
    Each record contains one SQS message.
    """
    processed = []
    failures = []

    for record in event['Records']:
        # Extract the SQS message body (always a string — parse the JSON)
        try:
            body = json.loads(record['body'])
            order_id = body.get('orderId', 'UNKNOWN')
            total_amount = body.get('totalAmount', 0)

            # Extract message attributes if present
            attrs = record.get('messageAttributes', {})
            priority = attrs.get('Priority', {}).get('stringValue', 'STANDARD')
            order_type = attrs.get('OrderType', {}).get('stringValue', 'WEB')

            logger.info(f"Processing order {order_id}, amount={total_amount}, "
                        f"priority={priority}, type={order_type}")

            # Validation rule: amount must be positive and <= 10000
            if total_amount <= 0 or total_amount > 10000:
                raise ValueError(f"Invalid amount {total_amount} for order {order_id}")

            processed.append(order_id)
            logger.info(f"Order {order_id} validated successfully")

        except Exception as e:
            logger.error(f"Failed to process record {record['messageId']}: {str(e)}")
            # Re-raise to signal failure to SQS (triggers redrive policy)
            # For partial batch failures, use batchItemFailures instead
            failures.append({
                'itemIdentifier': record['messageId']
            })

    logger.info(f"Batch complete: {len(processed)} processed, {len(failures)} failed")

    # Return partial batch failure report so SQS only retries failed messages
    # (requires "Report batch item failures" enabled on event source mapping)
    if failures:
        return {'batchItemFailures': failures}

    return {'statusCode': 200, 'processed': processed}
```

9. Click **Deploy**.

> **What Is Happening Behind the Scenes?** When Lambda is configured as an SQS event source, Lambda's internal polling infrastructure continuously polls the queue on your behalf (not your own code). When messages arrive, Lambda invokes your function with a **batch** of records in `event['Records']`. Your function processes all records in the batch. If the function succeeds (no exception, no batchItemFailures returned), Lambda automatically deletes all messages in the batch from the queue. If the function fails, no messages are deleted, and they become visible again for retry.

> **Common Beginner Mistake:** Thinking Lambda polls one message at a time. By default, Lambda polls in batches (default batch size 10). If your function raises an uncaught exception, the **entire batch** is retried — including successfully-processed messages. Use `batchItemFailures` (as shown above) to tell Lambda which specific messages failed so it only retries those.

### Step 11 — Configure the SQS event source mapping

1. On the `acme-order-validator` function page, click the **Configuration** tab → **Triggers** → **Add trigger**.
2. **Trigger source:** **SQS**.
3. **SQS queue:** select **acme-order-validation-queue**.
4. **Batch size:** `5` (process up to 5 messages per Lambda invocation).
5. **Batch window:** `0` seconds (invoke immediately when messages arrive; set to 1–300s to accumulate a larger batch before invoking).
6. Check **Report batch item failures** — this enables the `batchItemFailures` return value.
7. Click **Add**.

**Validation:** The trigger appears in the function's trigger list showing **acme-order-validation-queue** with an **Enabled** status. Lambda is now polling your queue automatically.

### Step 12 — Test the event source mapping end-to-end

1. Go back to **SQS** → **acme-order-validation-queue** → **Send and receive messages**.
2. Send a valid message:

```json
{
  "orderId": "A-10500",
  "customerId": "C-8821",
  "items": [{"sku": "BOOT-007", "qty": 1, "price": 199.99}],
  "totalAmount": 199.99,
  "orderTimestamp": "2026-07-12T10:00:00Z"
}
```

3. Add message attributes: `OrderId=A-10500`, `Priority=STANDARD`, `OrderType=WEB`.
4. Click **Send message**.
5. **Do not click Poll for messages** — Lambda is now polling automatically.
6. Within 20 seconds, navigate to **Lambda** → **acme-order-validator** → **Monitor** tab → **View CloudWatch logs**.
7. Click the most recent log stream.

**Validation:** You should see log lines like:
- `Processing order A-10500, amount=199.99, priority=STANDARD, type=WEB`
- `Order A-10500 validated successfully`
- `Batch complete: 1 processed, 0 failed`

Go back to SQS and poll the queue — it should be **empty** because Lambda automatically deleted the successfully processed message.

---

## Part 6: SQS Security Deep Dive

### Step 13 — Understanding Queue Access Policies

Every SQS queue has a **queue access policy** (a JSON resource-based policy) that controls which principals can perform which actions on the queue.

1. In the SQS console, click **acme-order-validation-queue** → **Access policy** tab.
2. You'll see the current policy (likely just the queue owner's account).

The following example shows a policy that allows a specific Lambda execution role to send messages and allows an SNS topic to deliver messages (common in fan-out architectures):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowLambdaToSend",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::YOUR_ACCOUNT_ID:role/acme-checkout-lambda-role"
      },
      "Action": "sqs:SendMessage",
      "Resource": "arn:aws:sqs:us-west-2:YOUR_ACCOUNT_ID:acme-order-validation-queue"
    },
    {
      "Sid": "AllowSNSToDeliver",
      "Effect": "Allow",
      "Principal": {
        "Service": "sns.amazonaws.com"
      },
      "Action": "sqs:SendMessage",
      "Resource": "arn:aws:sqs:us-west-2:YOUR_ACCOUNT_ID:acme-order-validation-queue",
      "Condition": {
        "ArnEquals": {
          "aws:SourceArn": "arn:aws:sns:us-west-2:YOUR_ACCOUNT_ID:acme-orders-topic"
        }
      }
    }
  ]
}
```

> **Security Consideration:** The `Condition` block with `aws:SourceArn` is critical when granting `sns.amazonaws.com` (or any service principal) access. Without it, **any SNS topic in any account** could potentially deliver messages to your queue. The condition locks it down to your specific topic — always include it for service principal grants.

> **Common Beginner Mistake:** Confusing the **queue access policy** (who can send/receive messages on the queue — resource-based policy) with the **Lambda execution role policy** (what the Lambda function itself can do — identity-based policy). For Lambda to receive from SQS via event source mapping, the Lambda execution role needs `sqs:ReceiveMessage`, `sqs:DeleteMessage`, and `sqs:GetQueueAttributes` permissions. The queue's access policy can additionally restrict which callers may enqueue messages.

### Step 14 — Review Lambda execution role permissions

Lambda's event source mapping requires specific SQS permissions on the Lambda execution role:

1. Navigate to **IAM** → **Roles** → search for `acme-order-validator`.
2. Click the role → **Permissions policies** tab.
3. The **AmazonSQSReadOnlyAccess** or similar policy should grant `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`.

> **Security Consideration:** The "Create new role with basic Lambda permissions" starter role only grants CloudWatch Logs permissions. AWS automatically adds the necessary SQS permissions when you create the event source mapping — but only for that specific queue ARN. This is **least privilege in action**: the role can only read from one specific queue, not any SQS queue in the account.

---

## Part 7: FIFO Queues — Ordering and Deduplication

### Step 15 — Create a FIFO queue for financial operations

Acme's finance team needs a separate queue for payment reversals. These must be processed **in strict order** and **never duplicated** (reversing the same charge twice would be catastrophic).

1. Click **Create queue**.
2. **Type:** **FIFO**.
3. **Name:** `acme-payment-reversals.fifo` (FIFO queue names MUST end in `.fifo`).
4. Under **Configuration**:
   - **Visibility timeout:** `60` seconds
   - **Message retention period:** `7 days`
   - Check **Content-based deduplication** — this automatically generates a deduplication ID from the message body's SHA-256 hash, so if you accidentally send the same message twice within 5 minutes, SQS discards the duplicate.
5. Enable **SSE-SQS** encryption.
6. Click **Create queue**.

### Step 16 — Send a message to the FIFO queue

1. Click **acme-payment-reversals.fifo** → **Send and receive messages**.
2. **Message body:**

```json
{
  "reversalId": "REV-001",
  "originalOrderId": "A-10427",
  "amount": -158.99,
  "reason": "Customer dispute — item not received",
  "initiatedBy": "cs-agent-42"
}
```

3. **Message group ID:** `customer-C-5512` (all reversals for the same customer go in the same group, ensuring they are processed in order for that customer while other customers' reversals proceed independently).
4. Leave **Message deduplication ID** empty — content-based deduplication will generate it automatically.
5. Click **Send message**.

> **AWS Mental Model — Message Groups:** A FIFO queue with message groups is like a multi-lane checkout line where each lane is strictly ordered. Customer A's reversals are always processed in order in lane A. Customer B's reversals proceed in their own lane B independently. This gives you both order (within a customer) and parallelism (across customers) — more scalable than a single-lane queue where every reversal blocks all other reversals.

6. Send the same message again (within 5 minutes). Note that SQS returns a success but the **duplicate message is silently discarded** due to content-based deduplication.

**Validation:** Poll the queue — only **one** message appears, not two. SQS deduplicated based on body hash.

---

## Part 8: CloudWatch Metrics for SQS

### Step 17 — Explore SQS CloudWatch metrics

1. Navigate to **CloudWatch** → **Metrics** → **All metrics**.
2. Click **SQS** namespace.
3. Click **Queue Name**.
4. In the search box, type `acme-order-validation-queue`.
5. Check the boxes for these metrics (add them to your graph):
   - **ApproximateNumberOfMessagesVisible** — messages waiting to be processed
   - **ApproximateNumberOfMessagesNotVisible** — messages currently in-flight (being processed)
   - **ApproximateAgeOfOldestMessage** — age in seconds of the oldest unprocessed message
   - **NumberOfMessagesSent** — messages sent in the period
   - **NumberOfMessagesDeleted** — messages successfully deleted (processed)

| Metric | What it tells you | Alert when... |
|---|---|---|
| `ApproximateNumberOfMessagesVisible` | Queue depth — processing backlog | Keeps growing (consumer can't keep up) |
| `ApproximateNumberOfMessagesNotVisible` | Active in-flight messages | Very high may indicate slow consumers |
| `ApproximateAgeOfOldestMessage` | How stale the oldest message is | Exceeds your SLA (e.g., > 5 minutes for orders) |
| `NumberOfMessagesSent` | Inflow rate | Sudden spike (traffic surge) |
| `NumberOfMessagesDeleted` | Successful processing rate | Much lower than Sent (messages not being completed) |

> **Common Beginner Mistake:** Alarming only on `ApproximateNumberOfMessagesVisible` (queue depth). A better signal is `ApproximateAgeOfOldestMessage` — it tells you how long the *oldest* order has been waiting, which directly maps to customer experience. A queue depth of 1,000 is fine if messages are flowing through quickly; an age of 10 minutes for a single message means something is stuck.

---

## Part 9: Advanced Concepts — Reference Material

### SQS Extended Client (Large Payloads)

SQS has a maximum message size of **256 KB**. For larger payloads (e.g., a product catalog update with 50,000 SKUs), use the **SQS Extended Client** pattern:

```
Producer
  |
  |-- 1. Upload large payload to S3 bucket
  |-- 2. Send SQS message containing S3 reference (bucket + key)
  |
  v
SQS Queue (stores tiny reference message, not the large payload)
  |
  v
Consumer
  |-- 3. Receive message, extract S3 reference
  |-- 4. Download full payload from S3
  |-- 5. Process payload
  |-- 6. Delete SQS message + S3 object
```

The AWS SDK provides an `SQSExtendedClient` library for Java. For Python, implement the pattern manually: upload to S3, put the S3 URL in the message body, download in the consumer. The message itself remains well under the 256 KB limit.

### Batch Processing Configuration

When your Lambda processes SQS messages:

- **Batch size (1–10,000):** Maximum messages per Lambda invocation. For CPU-intensive processing, use smaller batches. For I/O-bound work (database writes), larger batches reduce per-invocation overhead.
- **Batch window (0–300 seconds):** How long Lambda waits to collect a full batch before invoking. Use with irregular traffic to reduce invocation costs.
- **Maximum concurrency:** Limit how many concurrent Lambda invocations SQS can trigger. Useful to protect downstream systems from being overwhelmed.

### SQS + SNS Fan-Out Architecture

A common pattern at Acme Retail:

```
Checkout Service
      |
      v
   SNS Topic (acme-new-orders)
   /    |    \
  /     |     \
 v      v      v
SQS   SQS     SQS
Queue Queue   Queue
(validation) (analytics) (audit-log)
```

Each SQS queue has its own Lambda consumer. One order event fans out to three independent processing pipelines. No queue's failure affects the others.

---

## Checkpoint: Validation Before Challenges

Before attempting the challenges, verify:

- [ ] `acme-order-dlq` exists with 14-day retention and SSE enabled
- [ ] `acme-order-validation-queue` points to `acme-order-dlq` with maxReceiveCount=3
- [ ] `acme-fulfillment-queue` and `acme-notification-queue` exist with DLQ configured
- [ ] `acme-payment-reversals.fifo` exists with content-based deduplication
- [ ] `acme-order-validator` Lambda exists, deployed, and triggers from `acme-order-validation-queue`
- [ ] End-to-end test succeeded: message sent → Lambda processed → queue empty

---

## Challenges

> Attempt these challenges on your own before looking at the solutions in `07-solutions.md`. They test deep understanding of the concepts covered above.

### Challenge 1: VIP Order FIFO Queue with Priority Processing

Acme's marketing team wants VIP customers (loyalty tier "PLATINUM") to have their orders processed before standard customers, and **never** have their orders processed out-of-sequence (imagine a VIP placing three modifications to the same order — they must apply in order).

**Your task:**

1. Create a FIFO queue named `acme-vip-orders.fifo` with:
   - Content-based deduplication enabled
   - Visibility timeout of 45 seconds
   - SSE-SQS encryption
2. Create a new Lambda function named `acme-vip-order-processor` (Python 3.12) that:
   - Reads from `acme-vip-orders.fifo`
   - Logs the `MessageGroupId` and order details for each message
   - Uses the customer ID as the `MessageGroupId` (so each customer's orders are ordered independently)
3. Configure the Lambda event source mapping with batch size 1 (VIP orders get dedicated processing)
4. Send a test message to the FIFO queue with:
   - `MessageGroupId` = `customer-PLAT-001`
   - Body containing `orderId`, `customerId`, `tier=PLATINUM`, and `totalAmount`
5. Verify the Lambda logs show the message was processed with the correct group

**Bonus:** Send 3 messages with the same `MessageGroupId`. Verify they are processed in order by checking timestamps in CloudWatch Logs.

**Hints:**
- FIFO queues require `MessageGroupId` on every message sent
- Content-based deduplication uses the message body hash — two identical bodies within 5 minutes are considered duplicates
- Lambda event source mapping for FIFO queues works the same as Standard queues

---

### Challenge 2: DLQ Monitor Lambda with SNS Alert

The operations team needs to be notified (via SNS email) whenever a message lands in `acme-order-dlq`. Currently, messages silently pile up in the DLQ with no alerting.

**Your task:**

1. Create an SNS topic named `acme-dlq-alerts`
2. Subscribe your email address to `acme-dlq-alerts` and confirm the subscription
3. Create a Lambda function named `acme-dlq-monitor` (Python 3.12) that:
   - Triggers from `acme-order-dlq` (event source mapping, batch size 1)
   - Extracts the `orderId` from the message body (handle JSON parse errors gracefully)
   - Publishes a formatted alert to `acme-dlq-alerts` SNS topic with:
     - Subject: `[ALERT] Failed order in DLQ: {orderId}`
     - Message body including: orderId, receive count (from SQS metadata), approximate first receive timestamp, and the full message body
   - Logs the alert details to CloudWatch
   - **Does NOT delete the message** (leave messages in DLQ for human review — the Lambda should fail so the message stays) — actually think carefully about this: if you don't delete the message, Lambda will keep re-triggering. What is the right approach?
4. Grant the Lambda execution role permission to publish to the SNS topic
5. Test by sending a message to `acme-order-validation-queue` and receiving it 3 times without deleting (triggering the redrive to DLQ)
6. Verify you receive an email notification with the order details

**Hints:**
- Lambda needs `sns:Publish` permission on the specific SNS topic ARN
- SQS message attributes include `ApproximateReceiveCount` — look in `record['attributes']`
- Consider: after alerting, should the Lambda delete the message? What are the tradeoffs?

---

## Key Takeaways

1. **SQS decouples producers from consumers** with a durable buffer — slow/offline workers don't break the front end.
2. **Receiving ≠ deleting.** A received message is hidden for the visibility timeout; you must explicitly delete it after successful processing.
3. **Standard = at-least-once, best-effort order.** Design consumers to be idempotent.
4. **FIFO = exactly-once, strict order** within a message group — use when duplicates or out-of-order processing causes real business harm.
5. **DLQ + redrive policy** isolates poison messages that repeatedly fail, unblocking the main queue.
6. **Long polling (20 seconds)** is the production default — reduces cost and empty responses vs. short polling.
7. **SQS event source mapping** lets Lambda automatically poll, invoke, and delete — no polling code required.
8. **Message attributes** add lightweight metadata for routing/filtering without parsing the full body.
9. **SSE-SQS** encrypts at rest at zero additional cost — always enable in production.
10. **`ApproximateAgeOfOldestMessage`** is the most operationally meaningful SQS metric for customer-facing systems.

---

## Cleanup Instructions

Delete resources in this order to avoid dependency errors:

1. **Lambda event source mappings:**
   - Lambda → `acme-order-validator` → Configuration → Triggers → select the SQS trigger → Delete
   - Repeat for `acme-vip-order-processor` (if created for challenges)
   - Repeat for `acme-dlq-monitor` (if created for challenges)

2. **Lambda functions:**
   - Lambda → select each `acme-*` function → Actions → Delete

3. **Lambda IAM roles:**
   - IAM → Roles → search `acme-order-validator` → Delete (repeat for each role)

4. **SQS queues (delete in this order — DLQ last):**
   - `acme-payment-reversals.fifo` → Delete
   - `acme-vip-orders.fifo` (if created) → Delete
   - `acme-order-validation-queue` → Delete
   - `acme-fulfillment-queue` → Delete
   - `acme-notification-queue` → Delete
   - `acme-order-dlq` → Delete (last, after all queues that reference it)

5. **SNS topic (if created for Challenge 2):**
   - SNS → Subscriptions → delete `acme-dlq-alerts` subscription
   - SNS → Topics → delete `acme-dlq-alerts`

6. **CloudWatch Log groups:**
   - CloudWatch → Logs → Log groups → delete each `/aws/lambda/acme-*` log group

**Validation:** The SQS Queues list and Lambda Functions list show no `acme-*` resources.
