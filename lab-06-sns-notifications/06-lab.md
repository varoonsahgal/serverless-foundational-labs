# Lab 06: Order Notification Fanout with Amazon SNS

## Estimated Duration

~75 minutes

## Scenario / Business Context

**Acme Retail** places hundreds of orders per minute. When an order is confirmed, **five different systems** need to know about it simultaneously:

1. **Customer Email** — send a confirmation email to the buyer.
2. **Warehouse Lambda** — reserve inventory and trigger picking.
3. **Analytics Lambda** — record the order event for reporting dashboards.
4. **Priority Queue** — high-value orders (>$100) need special handling.
5. **Inventory Alert Team** — if a product goes low-stock after the order, alert the purchasing team.

Building point-to-point connections between the order system and all five receivers creates a tangled, brittle architecture. Adding a sixth receiver means changing the order system.

**Amazon SNS solves this with publish/subscribe (pub/sub) fanout.** The order system publishes one message to a topic. SNS delivers copies to all subscribers simultaneously — and adding a new subscriber never requires changing the publisher.

```
                    ┌──────────────────────┐
                    │  Order Lambda /      │
                    │  Order API           │
                    │  (Publisher)         │
                    └──────────┬───────────┘
                               │ Publish one message
                               ▼
                    ┌──────────────────────┐
                    │  SNS Topic:          │
                    │  acme-order-events   │
                    └──┬───┬───┬───┬───┬──┘
                       │   │   │   │   │
          ┌────────────┘   │   │   │   └───────────────┐
          ▼               ▼   ▼   │                   ▼
   Email Subscriber  Lambda  Lambda  │          SQS Queue
   (customer@...)   (warehouse) (analytics) │  (priority-orders)
                                     │
                               Filter Policy
                               (order.value > 100)
```

> **AWS Mental Model:** SNS is a **megaphone**. You shout once into the megaphone and everyone in the room hears it simultaneously. You don't need to know who is in the room — they subscribed themselves. Adding a new listener never requires changing the person holding the megaphone.

## Learning Objectives

By the end of this lab you will be able to:

1. Create an SNS **Standard topic** and explain when to use Standard vs. FIFO.
2. Create **multiple subscriber types**: email and Lambda.
3. Add **Message Attributes** to published messages.
4. Configure **Subscription Filter Policies** to route messages by attribute.
5. Write a **Lambda subscriber** that processes SNS notifications.
6. Explain the **SNS message envelope** (how SNS wraps your message before delivering it).
7. Describe **SNS + SQS fanout** patterns (conceptual, implemented in Lab 07).
8. Explain **Dead Letter Queues (DLQs)** for failed SNS deliveries.
9. Monitor SNS with **CloudWatch Metrics**.

## AWS Services Used

- **Amazon SNS** (Simple Notification Service)
- **AWS Lambda** (Python 3.12)
- **Amazon CloudWatch** (metrics and logs)
- Your email inbox (for the email subscription)

## Prerequisites

- An AWS account signed in as an IAM user (not root) with permissions for SNS, Lambda, and CloudWatch.
- Region set to **US West (Oregon) `us-west-2`** throughout this lab.
- A real email address you can receive mail at.
- Familiarity with Lambda from Lab 03.


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

## Part 1: SNS Core Concepts

### 1.1 Standard vs. FIFO Topics

| Feature | Standard Topic | FIFO Topic |
|---|---|---|
| **Throughput** | Nearly unlimited (millions/sec) | 300 messages/sec (3,000 with batching) |
| **Ordering** | Best-effort (not guaranteed) | Strictly ordered per message group |
| **Delivery** | At-least-once (may duplicate) | Exactly-once processing |
| **Subscribers** | Email, SMS, HTTP, Lambda, SQS, Kinesis | **Only SQS FIFO queues** |
| **Message filtering** | ✅ Supported | ✅ Supported |
| **Use case** | Notifications, fanout, alerts | Financial transactions, ordered event streams |
| **Name suffix** | None | Must end in `.fifo` |

> **When to choose FIFO:** Only when the **order of messages is business-critical** (e.g., a bank debit must be processed before the corresponding credit) AND you can accept the lower throughput limit. For order notifications (where "shipped" might occasionally arrive before "confirmed" with no real harm), Standard is the right choice.

### 1.2 The SNS Message Envelope

When SNS delivers a message to a **Lambda subscriber**, it wraps your original message in an envelope. Your Lambda receives a JSON structure like this:

```json
{
  "Records": [
    {
      "EventSource": "aws:sns",
      "EventVersion": "1.0",
      "EventSubscriptionArn": "arn:aws:sns:us-west-2:123456789012:acme-order-events:abc123",
      "Sns": {
        "Type": "Notification",
        "MessageId": "a7d3f8e0-1234-5678-abcd-ef0123456789",
        "TopicArn": "arn:aws:sns:us-west-2:123456789012:acme-order-events",
        "Subject": "Order Confirmed",
        "Message": "{\"orderId\": \"ORD-001\", \"totalAmount\": 149.97}",
        "Timestamp": "2026-07-12T14:23:01.000Z",
        "MessageAttributes": {
          "orderValue": {
            "Type": "Number",
            "Value": "149.97"
          },
          "eventType": {
            "Type": "String",
            "Value": "ORDER_CONFIRMED"
          }
        }
      }
    }
  ]
}
```

Key points:
- `Records` is always a **list** — SNS may batch multiple messages.
- `Sns.Message` is a **string** — even if you published JSON, it arrives as a JSON string. You must call `json.loads(record["Sns"]["Message"])` to get a dict.
- `Sns.MessageAttributes` contains the attributes you set when publishing — use these for routing and processing logic.

> **Common Beginner Mistake:** Treating `event["Sns"]["Message"]` as a dict. It is always a string. Always `json.loads()` it before accessing fields.

### 1.3 Subscription Filter Policies

Filter policies let each subscriber declare what subset of messages it wants. SNS evaluates the filter against the message's **MessageAttributes** and only delivers if the policy matches.

**Example filter policy (JSON attached to a subscription):**
```json
{
  "eventType": ["ORDER_CONFIRMED", "ORDER_UPDATED"],
  "orderValue": [{"numeric": [">=", 100]}]
}
```

This subscription only receives messages where `eventType` is `ORDER_CONFIRMED` or `ORDER_UPDATED` AND `orderValue >= 100`.

Filter policy scopes:
- **MessageAttributes** (default) — filter on the top-level message attributes.
- **MessageBody** — filter on fields inside the JSON message body (requires enabling body-level filtering, available since 2022).

---

## Part 2: Create the SNS Topic

### 2.1 Open SNS

1. Search for **SNS** in the AWS Console and open **Simple Notification Service**.
2. Confirm **Oregon (us-west-2)** in the top-right.

### 2.2 Create the Standard Topic

1. In the left nav, click **Topics → Create topic**.
2. **Type:** `Standard`
3. **Name:** `acme-order-events`
4. Expand **Access policy** (leave at default — only your account can publish and subscribe).
5. Leave **Encryption** disabled (acceptable for non-sensitive notification metadata in this lab; enable SSE for PII in production).
6. Leave **Delivery retry policy** at defaults (3 retries, exponential backoff).
7. Click **Create topic**.

**Validation:** You land on the topic detail page. Note the **Topic ARN**:
```
arn:aws:sns:us-west-2:123456789012:acme-order-events
```
Save this ARN — you'll use it when publishing from a Lambda later.

> **Security Consideration:** The **Access Policy** on an SNS topic is a resource-based IAM policy that controls who can publish to and subscribe from the topic. The default policy allows only your AWS account. If you need another AWS account or an AWS service (e.g., S3 event notifications) to publish to your topic, you modify this policy — you do NOT share credentials.

---

## Part 3: Create the Email Subscription

### 3.1 Subscribe an Email Address

1. On the `acme-order-events` topic page, click **Create subscription**.
2. **Protocol:** `Email`
3. **Endpoint:** your email address (one you can actually receive mail at).
4. Leave all other settings at defaults.
5. Click **Create subscription**.

**Status:** The subscription will show **Pending confirmation**.

### 3.2 Confirm the Email Subscription

1. Check your inbox for an email from **AWS Notifications** with subject **"AWS Notification - Subscription Confirmation"**.
2. Click the **Confirm subscription** link in the email.
3. Your browser will show **"Subscription confirmed!"**.

**Validation:** In the SNS console → **Subscriptions**, refresh and confirm the status is **Confirmed**.

> **What Is Happening Behind the Scenes?** SNS requires email subscriptions to be confirmed because otherwise, anyone could subscribe your email address to a topic you never signed up for (effectively weaponizing SNS as a spam tool). The confirmation step proves you own the inbox. SQS and Lambda subscriptions are auto-confirmed because AWS can verify ownership through IAM.

> **Common Beginner Mistake:** Publishing a test message before the subscription is confirmed and wondering why no email arrived. Always confirm subscriptions before testing.

---

## Part 4: Create Lambda Subscribers

### 4.1 Create the Warehouse Order Processor Lambda

This Lambda simulates the warehouse system — it receives every order event and logs inventory reservation actions.

1. Open **Lambda** → **Create function** → **Author from scratch**.
2. **Function name:** `acme-warehouse-processor`
3. **Runtime:** `Python 3.12`
4. **Architecture:** `x86_64`
5. Leave default permissions, click **Create function**.
6. Replace code and click **Deploy**:

```python
import json
import time


def lambda_handler(event, context):
    """
    Warehouse processor — receives all ORDER_CONFIRMED events via SNS.
    Simulates inventory reservation and picking workflow.
    """
    for record in event.get("Records", []):
        # SNS always wraps the message in an envelope
        sns_envelope = record.get("Sns", {})
        topic_arn = sns_envelope.get("TopicArn", "unknown")
        message_id = sns_envelope.get("MessageId", "unknown")

        # The actual message body is a JSON string — must be parsed
        raw_message = sns_envelope.get("Message", "{}")
        try:
            order = json.loads(raw_message)
        except json.JSONDecodeError as e:
            print(f"ERROR: Could not parse SNS message body: {e}")
            print(f"Raw message: {raw_message}")
            continue

        # Extract message attributes (for routing / metadata)
        message_attributes = sns_envelope.get("MessageAttributes", {})
        event_type = message_attributes.get("eventType", {}).get("Value", "UNKNOWN")
        order_value = message_attributes.get("orderValue", {}).get("Value", "0")

        order_id = order.get("orderId", "UNKNOWN")
        customer_id = order.get("customerId", "UNKNOWN")
        items = order.get("items", [])

        print(f"[WAREHOUSE] Received event: {event_type} | Order: {order_id} | Value: ${order_value}")
        print(f"[WAREHOUSE] Customer: {customer_id} | Items: {len(items)}")

        # Simulate inventory reservation
        for item in items:
            product_id = item.get("productId", "UNKNOWN")
            quantity = item.get("quantity", 1)
            print(f"[WAREHOUSE] Reserving {quantity}x {product_id} for order {order_id}")
            # In production: update DynamoDB inventory table here

        print(f"[WAREHOUSE] ✅ Order {order_id} queued for picking (message: {message_id})")

    return {"statusCode": 200, "body": "Warehouse processing complete"}
```

### 4.2 Create the Analytics Logger Lambda

This Lambda records every order event for the reporting team.

1. **Create function** → name: `acme-analytics-logger`, runtime `Python 3.12`.
2. Replace code and deploy:

```python
import json
import time


def lambda_handler(event, context):
    """
    Analytics logger — receives all order events and logs structured data
    for reporting dashboards. In production, would write to Kinesis, S3, or DynamoDB.
    """
    processed_count = 0

    for record in event.get("Records", []):
        sns_envelope = record.get("Sns", {})
        message_id = sns_envelope.get("MessageId", "unknown")
        timestamp = sns_envelope.get("Timestamp", "unknown")

        raw_message = sns_envelope.get("Message", "{}")
        try:
            order = json.loads(raw_message)
        except json.JSONDecodeError:
            print(f"ERROR: Invalid JSON in SNS message {message_id}")
            continue

        message_attributes = sns_envelope.get("MessageAttributes", {})
        event_type = message_attributes.get("eventType", {}).get("Value", "UNKNOWN")
        order_value = float(message_attributes.get("orderValue", {}).get("Value", "0"))

        # Structured analytics event
        analytics_event = {
            "eventType": event_type,
            "orderId": order.get("orderId"),
            "customerId": order.get("customerId"),
            "totalAmount": order.get("totalAmount"),
            "itemCount": len(order.get("items", [])),
            "isHighValue": order_value >= 100,
            "snsMessageId": message_id,
            "receivedAt": timestamp,
        }

        print(f"[ANALYTICS] Event recorded: {json.dumps(analytics_event)}")
        # In production: write to DynamoDB, push to Kinesis Data Firehose → S3, etc.

        processed_count += 1

    print(f"[ANALYTICS] Processed {processed_count} events in this batch")
    return {"statusCode": 200, "processed": processed_count}
```

---

## Part 5: Subscribe the Lambda Functions to the Topic

### 5.1 Subscribe acme-warehouse-processor

1. On the `acme-order-events` topic, click **Create subscription**.
2. **Protocol:** `AWS Lambda`
3. **Endpoint:** click the textbox and type/select `acme-warehouse-processor`. You can also paste the full Lambda ARN (find it in the Lambda console under the function name).
4. **Subscription filter policy:** leave empty for now — this Lambda will receive ALL messages.
5. Click **Create subscription**.

> **What Is Happening Behind the Scenes?** When you create a Lambda subscription, SNS automatically adds a **resource-based policy** to the Lambda function granting SNS permission to invoke it. You can verify this: Lambda console → `acme-warehouse-processor` → Configuration → Permissions → Resource-based policy statements. You'll see a statement allowing `sns:Publish` from your topic's ARN.

### 5.2 Subscribe acme-analytics-logger (with a Filter Policy)

The analytics team only wants `ORDER_CONFIRMED` and `ORDER_SHIPPED` events — not internal status updates.

1. Click **Create subscription** again.
2. **Protocol:** `AWS Lambda`
3. **Endpoint:** `acme-analytics-logger`
4. Under **Subscription filter policy**, paste the following JSON:
   ```json
   {
     "eventType": ["ORDER_CONFIRMED", "ORDER_SHIPPED"]
   }
   ```
5. Click **Create subscription**.

> **What Is Happening Behind the Scenes? — Filter Policy Evaluation:** When SNS receives a published message, it evaluates the filter policy against the message's `MessageAttributes`. If the `eventType` attribute's value is in the allowed list, the message is delivered. If not, SNS silently drops it for that subscription — the other subscribers (warehouse, email) still receive it. Each subscriber gets its own filter policy.

---

## Part 6: Publish Messages with Message Attributes

### 6.1 Publish an Order Confirmed Event from the Console

1. On the `acme-order-events` topic, click **Publish message**.
2. **Subject:** `Order Confirmed - ORD-001`
3. **Message body:**
   ```json
   {
     "orderId": "ORD-001",
     "customerId": "CUST-001",
     "totalAmount": 149.97,
     "items": [
       {"productId": "P001", "name": "Wireless Headphones", "price": 79.99, "quantity": 1},
       {"productId": "P004", "name": "Yoga Mat", "price": 34.99, "quantity": 2}
     ],
     "status": "CONFIRMED",
     "shippingAddress": "42 Retail Lane, Seattle, WA 98101"
   }
   ```
4. Scroll to **Message attributes** and add two attributes:
   - Attribute 1:
     - **Name:** `eventType`
     - **Type:** `String`
     - **Value:** `ORDER_CONFIRMED`
   - Attribute 2:
     - **Name:** `orderValue`
     - **Type:** `Number`
     - **Value:** `149.97`
5. Click **Publish message**.

**Wait 10–30 seconds**, then:

**Validation A — Email:** Check your inbox. You should receive an email from SNS with subject `Order Confirmed - ORD-001` and the JSON body. The email arrives because your email subscription has **no filter policy** (receives everything).

**Validation B — Warehouse Lambda:** Go to **Lambda → acme-warehouse-processor → Monitor → View CloudWatch logs**. Open the latest log stream. You should see lines like:
```
[WAREHOUSE] Received event: ORDER_CONFIRMED | Order: ORD-001 | Value: $149.97
[WAREHOUSE] Reserving 1x P001 for order ORD-001
[WAREHOUSE] Reserving 2x P004 for order ORD-001
[WAREHOUSE] ✅ Order ORD-001 queued for picking
```

**Validation C — Analytics Lambda:** Go to **Lambda → acme-analytics-logger → Monitor → View CloudWatch logs**. You should see `ORDER_CONFIRMED` was received. The `isHighValue` field should be `true` ($149.97 > $100).

### 6.2 Publish a Low-Value Order (Test the Filter Policy)

Publish another message with `eventType = ORDER_CONFIRMED` and `orderValue = 25.00`:

1. **Publish message** → new body with `"orderId": "ORD-002", "totalAmount": 25.00`.
2. **Message attributes:** `eventType = ORDER_CONFIRMED`, `orderValue = 25.00`.

**Expected behavior:**
- **Email subscriber:** receives it ✅ (no filter policy).
- **Warehouse Lambda:** receives it ✅ (no filter policy).
- **Analytics Lambda:** receives it ✅ (eventType matches `ORDER_CONFIRMED` — the filter policy only filters on eventType, not orderValue).

### 6.3 Publish an Internal Status Update (eventType = INVENTORY_CHECK)

1. **Publish message** → any body, set `eventType = INVENTORY_CHECK`, `orderValue = 0`.

**Expected behavior:**
- **Email subscriber:** receives it ✅ (no filter).
- **Warehouse Lambda:** receives it ✅ (no filter).
- **Analytics Lambda:** DOES NOT receive it ✅ — `INVENTORY_CHECK` is not in the filter policy `["ORDER_CONFIRMED", "ORDER_SHIPPED"]`. SNS silently drops it for this subscription.

**Validate filtering worked:** Check the analytics Lambda's CloudWatch logs after this publish. There should be **no new log entry** for the `INVENTORY_CHECK` message — the subscription filter blocked it.

---

## Part 7: Dead Letter Queues for SNS Subscriptions

When SNS fails to deliver a message to a subscriber (Lambda is throttled, HTTP endpoint returns 5xx, etc.), it retries with exponential backoff. If all retries fail, the message can be sent to a **Dead Letter Queue (DLQ)** — an SQS queue where failed messages accumulate for later inspection and reprocessing.

### Why DLQs matter

Without a DLQ, failed deliveries are silently discarded — you have no record that a message wasn't delivered. With a DLQ, you can:
- Alert when messages enter the DLQ (CloudWatch Alarm on `NumberOfMessagesSent` for the queue).
- Inspect the messages to understand why delivery failed.
- Replay messages after fixing the root cause.

### Configuring a DLQ (Conceptual Steps)

1. Create an **SQS Standard queue** named `acme-order-events-dlq` (you'll learn SQS in Lab 07).
2. When creating (or editing) an SNS subscription for a Lambda, find the **Redrive policy (dead-letter queue)** section.
3. Set the DLQ ARN to your SQS queue's ARN.
4. SNS will write failed deliveries to the DLQ after exhausting its retry policy.

> **Cost Awareness:** SQS queues have a free tier (1 million requests/month free). DLQ messages remain in the queue for up to 14 days (configurable). Always set up CloudWatch Alarms on your DLQ's depth so you're notified when something starts failing silently.

---

## Part 8: SNS + SQS Fanout Pattern (Preview of Lab 07)

The **SNS → SQS fanout** pattern is one of the most common and powerful patterns in AWS serverless architecture:

```
Publisher → SNS Topic → SQS Queue A → Lambda Consumer A (scale independently)
                      → SQS Queue B → Lambda Consumer B (scale independently)
                      → SQS Queue C → Lambda Consumer C (scale independently)
```

**Why use queues between SNS and Lambda?**

| Concern | SNS → Lambda (direct) | SNS → SQS → Lambda |
|---|---|---|
| **Buffering** | No — if Lambda is throttled, delivery fails | Yes — messages wait in queue, processed when Lambda is available |
| **Backpressure** | No — SNS delivers as fast as messages arrive | Yes — queue absorbs bursts, Lambda processes at its own rate |
| **Replay failed messages** | Only via DLQ (limited) | Yes — SQS DLQ + redrive policy makes replay easy |
| **Multiple consumers per subscriber** | No — one Lambda per subscription | No — but you can have a consumer group pattern with SQS |
| **Message retention** | 0 (dropped if undelivered) | Up to 14 days |
| **Best for** | Real-time, latency-sensitive processing | High-reliability, decoupled processing |

You will implement the `SNS → SQS → Lambda` pattern in **Lab 07**. For now, understand that the combination of SNS (fanout) + SQS (buffering) gives you both broadcast delivery AND reliable processing.

---

## Part 9: CloudWatch Metrics for SNS

SNS publishes metrics to CloudWatch automatically — no configuration needed.

### 9.1 View SNS Metrics

1. Go to **CloudWatch → Metrics → All metrics**.
2. Search for **SNS**.
3. Under **SNS → Topic Metrics**, select `acme-order-events`.

Key metrics to know:

| Metric | What it measures |
|---|---|
| `NumberOfMessagesPublished` | Messages successfully published to the topic |
| `NumberOfNotificationsDelivered` | Messages successfully delivered to ALL confirmed subscribers |
| `NumberOfNotificationsFailed` | Delivery failures (triggers DLQ if configured) |
| `NumberOfNotificationsFilteredOut` | Messages blocked by a subscription filter policy |
| `NumberOfNotificationsFilteredOut-NoMessageAttributes` | Messages with no attributes that were blocked by a filter requiring attributes |

### 9.2 View Filtered-Out Count

After publishing the `INVENTORY_CHECK` message (Part 6.3), you should see a `NumberOfNotificationsFilteredOut` datapoint of `1` for the analytics Lambda subscription.

1. In CloudWatch → Metrics, look for `NumberOfNotificationsFilteredOut` for `acme-order-events`.
2. Change the period to **1 minute** and look at the time you published the message.

> **Why This Matters:** `NumberOfNotificationsFilteredOut` being nonzero is not an error — it means filtering is working as intended. But `NumberOfNotificationsFailed` being nonzero is a problem to investigate. Set a CloudWatch Alarm on `NumberOfNotificationsFailed` for your production topics.

---

## Key Takeaways

- **SNS = push, pub/sub, fanout.** One message, many subscribers. Publisher doesn't know or care who is subscribed.
- **Standard topics** offer unlimited throughput and at-least-once delivery. **FIFO topics** add ordering and exactly-once but require SQS FIFO subscribers and have lower throughput.
- **Email subscriptions must be manually confirmed** before they receive messages.
- **Lambda subscriptions are auto-confirmed** (AWS verifies ownership via IAM).
- **The SNS message envelope** wraps your message in `Records[n].Sns.Message` (a JSON string). Always `json.loads()` it.
- **Message Attributes** are key-value pairs attached to a published message. They are the basis for filter policies.
- **Subscription Filter Policies** let each subscriber declare what messages it wants. SNS drops non-matching messages for that subscriber (other subscribers unaffected). This is evaluated against MessageAttributes (or optionally the message body).
- **DLQs** capture failed deliveries for inspection and replay — essential in production.
- **SNS → SQS → Lambda** combines broadcast (SNS) with reliable buffered processing (SQS). Covered in Lab 07.
- **CloudWatch metrics** for SNS are automatic. Watch `NumberOfNotificationsFailed` in production.

---

## Challenge Exercises

Solutions are in `06-solutions.md`.

### Challenge 1: Add a Second Topic for Inventory Alerts with Filter-Based Routing

Acme's purchasing team needs to know when products run low after orders. Set up a second notification pipeline:

1. Create a new SNS Standard topic named `acme-inventory-alerts`.
2. Subscribe two email addresses (you can use the same inbox twice with `+alias` addresses like `you+purchasing@gmail.com` and `you+ops@gmail.com`).
3. Create a filter policy on one subscription so it only receives `lowStockAlert` messages where `severity = "CRITICAL"`.
4. Create a filter policy on the other subscription so it receives all `lowStockAlert` messages regardless of severity.
5. Publish two test messages:
   - One with `alertType = lowStockAlert`, `severity = CRITICAL`
   - One with `alertType = lowStockAlert`, `severity = WARNING`
6. Verify that only the `CRITICAL` message reaches the critical-only subscription, while both messages reach the all-alerts subscription.

**Deliverable:** Document the two filter policy JSONs and show which messages each subscription received.

---

### Challenge 2: Lambda Subscriber that Routes High-Value Orders

Create a Lambda function that processes SNS messages and routes high-value orders (totalAmount > $100) to a special log:

1. Create a Lambda function named `acme-priority-router` (Python 3.12).
2. Subscribe it to `acme-order-events` with a filter policy that only delivers messages with `eventType = ORDER_CONFIRMED`.
3. In the Lambda code, inspect the `totalAmount` from the parsed message body:
   - If `totalAmount > 100`: log `[PRIORITY] HIGH-VALUE ORDER: {orderId} - ${totalAmount}` and a simulated escalation action.
   - If `totalAmount <= 100`: log `[STANDARD] Order {orderId} - ${totalAmount} - standard processing`.
4. Publish two test orders:
   - `orderId: ORD-HIGH`, `totalAmount: 249.99` → should log `[PRIORITY]`
   - `orderId: ORD-LOW`, `totalAmount: 19.99` → should log `[STANDARD]`
5. Verify via CloudWatch Logs that both orders were processed and classified correctly.

---

## Cleanup Instructions

### 1. Delete SNS Subscriptions

1. Go to **SNS → Subscriptions**.
2. Select each subscription for `acme-order-events` → **Delete** → confirm.

### 2. Delete the SNS Topics

1. Go to **SNS → Topics**.
2. Select `acme-order-events` → **Delete** → type `delete me` → confirm.
3. If you created `acme-inventory-alerts` for Challenge 1, delete it too.

### 3. Delete the Lambda Functions

1. Go to **Lambda → Functions**.
2. Delete `acme-warehouse-processor`, `acme-analytics-logger`.
3. If you created `acme-priority-router` for Challenge 2, delete it too.

### 4. Delete CloudWatch Log Groups

1. Go to **CloudWatch → Log groups**.
2. Delete `/aws/lambda/acme-warehouse-processor`, `/aws/lambda/acme-analytics-logger`, and any others created during this lab.

> **Cost Awareness:** SNS Standard topics have a very generous free tier (first 1 million Amazon SNS requests per month are free). Lambda has a free tier of 1 million invocations per month. The main charges to watch are CloudWatch Logs storage and any email delivery beyond the free tier. Deleting these resources after the lab guarantees no ongoing cost.
