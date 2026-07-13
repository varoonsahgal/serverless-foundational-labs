# Lab 08: Orchestrating a Multi-Step Order Workflow with AWS Step Functions

## Estimated Duration

~105 minutes

## Scenario / Business Context

**Acme Retail** processes 50,000 orders per day. The current order processing code is a 400-line Lambda function called `mega-order-handler` that does everything sequentially: validate the order, check inventory, charge the customer's card, send a confirmation email, update the warehouse picking system, and record the transaction for accounting. When a bug was introduced last month, the team spent three days tracing through log output to find which of the six steps had failed, and for which orders. Three orders were charged but never fulfilled — the customers are still waiting.

The new architecture replaces `mega-order-handler` with a **visual workflow** built in **AWS Step Functions**. Each step is explicitly modeled, visually inspectable, and independently retryable. When something fails, the execution history shows exactly which state failed, what the input was, what the error was, and whether retry attempts were made.

Here is the target workflow:

```
                    START
                      |
              [Validate Order]  <-- Task state: calls acme-validate-order Lambda
                      |
              [Check Inventory]  <-- Task state: calls acme-check-inventory Lambda
                      |
               [In Stock?]  <-- Choice state: branches on inventoryAvailable
              /            \
          YES               NO
           |                 |
   [Process Payment]   [Out of Stock]  <-- Fail state
    (with Retry)
           |
   [Wait 3 Seconds]  <-- Wait state: simulate payment processing delay
           |
   [Notify & Record]  <-- Parallel state: runs two branches simultaneously
   /                \
[Send Confirmation]  [Update Analytics]
(calls Lambda)       (calls Lambda)
           |
      [Fulfill Order]  <-- Task state: calls warehouse Lambda
           |
        [Succeed]
```

> **AWS Mental Model:** Think of Step Functions as a **choreography director** for your microservices. Each Lambda function is a musician who knows only their own part. Step Functions is the conductor who tells each musician when to play, waits for them to finish, decides what happens next, and can ask a musician to play again if they missed a note. The sheet music (the state machine definition) is visible, version-controlled, and auditable.

## Learning Objectives

By the end of this lab you will be able to:

1. Explain what a Step Functions **state machine** and **execution** are.
2. Choose between **Standard** and **Express** workflow types.
3. Build workflows using **Task**, **Choice**, **Wait**, **Pass**, **Succeed**, **Fail**, **Parallel**, and **Map** states.
4. Implement **error handling** with `Retry` and `Catch` blocks including backoff.
5. Use **InputPath**, **OutputPath**, **ResultPath**, and **Parameters** to control JSON flow.
6. Enable **X-Ray tracing** for distributed trace visualization.
7. Understand **SDK integrations vs. optimized integrations**.
8. Describe the **callback pattern** with `.waitForTaskToken`.

## AWS Services Used

- **AWS Step Functions** — workflow orchestration
- **AWS Lambda** — the function each workflow step calls
- **AWS X-Ray** — distributed tracing
- **AWS IAM** — execution role for the state machine
- **Amazon CloudWatch Logs** — execution logs

## Prerequisites

- AWS account with an IAM user (not root) with permissions for Step Functions, Lambda, IAM, X-Ray, and CloudWatch.
- Working in **US West (Oregon) `us-west-2`**. Confirm the region before every step.

---

## Part 1: Standard vs. Express Workflows — The Decision

Before building anything, understand the two workflow types. This is a frequently tested AWS concept.

| Feature | Standard Workflow | Express Workflow |
|---|---|---|
| **Max duration** | 1 year | 5 minutes |
| **Execution model** | Exactly-once per state | At-least-once |
| **Execution history** | Full visual history in console (90 days) | CloudWatch Logs only |
| **Pricing** | Per state transition | Per execution + per GB-second duration |
| **Use case** | Order processing, approval flows, long-running jobs | High-volume event processing, IoT, streaming |
| **Audit** | Full audit trail built-in | Must enable CloudWatch Logs for audit |
| **Concurrency** | Up to 1 million open executions | Up to 100,000/second start rate |

> **Decision Rule:** If you need to **audit individual executions** (e.g., "show me exactly what happened to order #A-10427 and why it was rejected"), use **Standard**. If you're processing millions of events per minute (IoT sensor readings, clickstream events) and don't need per-execution audit trails, use **Express**.

> **Common Beginner Mistake:** Assuming Standard workflows are "better." Express workflows are substantially cheaper for high-throughput short-duration work. A batch of 10 million Express executions per day costs a fraction of the same volume in Standard. Choose based on your requirements.

For Acme's order workflow: use **Standard** — orders must be fully auditable.

---

## Part 2: Create the Lambda Functions

### Step 1 — Create `acme-validate-order` Lambda

1. Navigate to **Lambda**. Confirm region is **us-west-2**.
2. **Create function** → **Author from scratch**.
3. **Function name:** `acme-validate-order`
4. **Runtime:** **Python 3.12**
5. Leave **Create a new role with basic Lambda permissions** selected.
6. Click **Create function**.
7. Replace the code with:

```python
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    """
    Validates an incoming order.
    Returns the order with a validation result.
    """
    order_id = event.get('orderId', 'UNKNOWN')
    amount = event.get('totalAmount', 0)
    customer_id = event.get('customerId', 'UNKNOWN')
    items = event.get('items', [])

    logger.info(f"Validating order {order_id} for customer {customer_id}, amount={amount}")

    # Validation rules
    errors = []
    if amount <= 0:
        errors.append("Order amount must be positive")
    if amount > 50000:
        errors.append("Order amount exceeds maximum of $50,000")
    if not items:
        errors.append("Order must contain at least one item")
    if not customer_id or customer_id == 'UNKNOWN':
        errors.append("Valid customer ID required")

    valid = len(errors) == 0

    if valid:
        logger.info(f"Order {order_id} passed validation: {len(items)} items, ${amount}")
    else:
        logger.warning(f"Order {order_id} failed validation: {errors}")

    return {
        "orderId": order_id,
        "customerId": customer_id,
        "totalAmount": amount,
        "items": items,
        "validationPassed": valid,
        "validationErrors": errors
    }
```

8. Click **Deploy**.

### Step 2 — Create `acme-check-inventory` Lambda

1. **Create function** → **Author from scratch**.
2. **Name:** `acme-check-inventory`, **Runtime:** Python 3.12.
3. Replace code with:

```python
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Simulated inventory (in production, this would query DynamoDB)
INVENTORY = {
    "SHOE-001": 45,
    "SHIRT-042": 12,
    "BOOT-007": 3,
    "HANDBAG-LUX-001": 0,   # Out of stock
    "WATCH-PRE-001": 2,
}

def lambda_handler(event, context):
    order_id = event.get('orderId', 'UNKNOWN')
    items = event.get('items', [])

    logger.info(f"Checking inventory for order {order_id}, {len(items)} items")

    unavailable_items = []
    for item in items:
        sku = item.get('sku', 'UNKNOWN')
        qty_requested = item.get('qty', 1)
        available = INVENTORY.get(sku, 0)

        if available < qty_requested:
            unavailable_items.append({
                "sku": sku,
                "requested": qty_requested,
                "available": available
            })
            logger.warning(f"Insufficient stock for {sku}: requested={qty_requested}, available={available}")

    inventory_available = len(unavailable_items) == 0

    if inventory_available:
        logger.info(f"All items in stock for order {order_id}")
    else:
        logger.warning(f"Order {order_id} has {len(unavailable_items)} out-of-stock items")

    return {
        **event,  # Pass through all fields from validation step
        "inventoryAvailable": inventory_available,
        "unavailableItems": unavailable_items
    }
```

4. Click **Deploy**.

### Step 3 — Create `acme-process-payment` Lambda

1. **Create function** → **Name:** `acme-process-payment`, **Runtime:** Python 3.12.
2. Replace code with:

```python
import json
import logging
import random

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    """
    Simulates payment processing. Occasionally raises a retryable error
    to demonstrate Step Functions Retry behavior.
    """
    order_id = event.get('orderId', 'UNKNOWN')
    amount = event.get('totalAmount', 0)
    customer_id = event.get('customerId', 'UNKNOWN')

    logger.info(f"Processing payment for order {order_id}, amount=${amount}, customer={customer_id}")

    # Simulate a transient payment gateway error (20% chance)
    # This lets you observe the Retry block in action
    if random.random() < 0.2:
        raise Exception("PaymentGatewayTransientError: upstream payment processor returned 503")

    # Simulate payment processing
    transaction_id = f"TXN-{order_id}-{int(amount * 100)}"
    logger.info(f"Payment approved for order {order_id}, transaction={transaction_id}")

    return {
        **event,
        "paymentStatus": "APPROVED",
        "transactionId": transaction_id
    }
```

3. Click **Deploy**.

### Step 4 — Create `acme-send-confirmation` Lambda

1. **Name:** `acme-send-confirmation`, **Runtime:** Python 3.12.
2. Replace code with:

```python
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    order_id = event.get('orderId', 'UNKNOWN')
    customer_id = event.get('customerId', 'UNKNOWN')
    transaction_id = event.get('transactionId', 'UNKNOWN')
    amount = event.get('totalAmount', 0)

    confirmation_number = f"ACME-CONF-{order_id}"
    logger.info(f"Sending confirmation for order {order_id} to customer {customer_id}")
    logger.info(f"Confirmation number: {confirmation_number}, Transaction: {transaction_id}")

    # In production: send email via SES, push notification via SNS, etc.

    return {
        "confirmationNumber": confirmation_number,
        "customerId": customer_id,
        "notificationSent": True,
        "channel": "EMAIL"
    }
```

3. Click **Deploy**.

### Step 5 — Create `acme-update-analytics` Lambda

1. **Name:** `acme-update-analytics`, **Runtime:** Python 3.12.
2. Replace code with:

```python
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    order_id = event.get('orderId', 'UNKNOWN')
    amount = event.get('totalAmount', 0)
    customer_id = event.get('customerId', 'UNKNOWN')

    logger.info(f"Recording analytics for order {order_id}: customer={customer_id}, amount={amount}")

    # In production: write to Kinesis Data Firehose → S3 → Athena
    # Or update DynamoDB counters, push to CloudWatch custom metrics

    return {
        "analyticsRecorded": True,
        "orderId": order_id,
        "revenueRecorded": amount
    }
```

3. Click **Deploy**.

### Step 6 — Create `acme-fulfill-order` Lambda

1. **Name:** `acme-fulfill-order`, **Runtime:** Python 3.12.
2. Replace code with:

```python
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    order_id = event.get('orderId', 'UNKNOWN')
    items = event.get('items', [])
    transaction_id = event.get('transactionId', 'UNKNOWN')

    fulfillment_id = f"FULFILL-{order_id}"
    logger.info(f"Creating fulfillment for order {order_id} ({len(items)} items), fulfillmentId={fulfillment_id}")

    # In production: send picking request to warehouse management system
    # Reserve shipping label, update inventory counts in DynamoDB

    return {
        "orderId": order_id,
        "fulfillmentId": fulfillment_id,
        "itemCount": len(items),
        "transactionId": transaction_id,
        "fulfillmentStatus": "QUEUED_FOR_PICKING",
        "estimatedShipDate": "2026-07-13"
    }
```

3. Click **Deploy**.

**Validation for Part 2:** All 6 Lambda functions listed in the Lambda console in us-west-2:
- `acme-validate-order`
- `acme-check-inventory`
- `acme-process-payment`
- `acme-send-confirmation`
- `acme-update-analytics`
- `acme-fulfill-order`

---

## Part 3: Build the State Machine

### Step 7 — Open Step Functions and create the state machine

1. Console search bar → **Step Functions** → confirm region **us-west-2**.
2. Click **State machines** → **Create state machine**.
3. Choose **Blank** template → **Select**.
4. You are in **Workflow Studio** in Design mode.
5. In the top toolbar, confirm **Type** is **Standard**.

### Step 8 — Build the workflow using ASL (recommended approach)

While Workflow Studio's drag-and-drop is good for learning, pasting the full ASL gives you precise control. Click the **{} Code** button to switch to code view and **replace all content** with the following ASL:

```json
{
  "Comment": "Acme Retail order fulfillment workflow: validate → inventory → payment → notify+record → fulfill",
  "StartAt": "Validate Order",
  "States": {
    "Validate Order": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "acme-validate-order",
        "Payload.$": "$"
      },
      "ResultSelector": {
        "orderId.$": "$.Payload.orderId",
        "customerId.$": "$.Payload.customerId",
        "totalAmount.$": "$.Payload.totalAmount",
        "items.$": "$.Payload.items",
        "validationPassed.$": "$.Payload.validationPassed",
        "validationErrors.$": "$.Payload.validationErrors"
      },
      "Retry": [
        {
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "Next": "Workflow Error",
          "ResultPath": "$.error"
        }
      ],
      "Next": "Check Inventory"
    },
    "Check Inventory": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "acme-check-inventory",
        "Payload.$": "$"
      },
      "ResultSelector": {
        "orderId.$": "$.Payload.orderId",
        "customerId.$": "$.Payload.customerId",
        "totalAmount.$": "$.Payload.totalAmount",
        "items.$": "$.Payload.items",
        "validationPassed.$": "$.Payload.validationPassed",
        "inventoryAvailable.$": "$.Payload.inventoryAvailable",
        "unavailableItems.$": "$.Payload.unavailableItems"
      },
      "Retry": [
        {
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "Next": "Workflow Error",
          "ResultPath": "$.error"
        }
      ],
      "Next": "In Stock?"
    },
    "In Stock?": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.inventoryAvailable",
          "BooleanEquals": true,
          "Next": "Process Payment"
        }
      ],
      "Default": "Out of Stock"
    },
    "Out of Stock": {
      "Type": "Fail",
      "Error": "OutOfStock",
      "Cause": "One or more items in the order are not available in inventory."
    },
    "Process Payment": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "acme-process-payment",
        "Payload.$": "$"
      },
      "ResultSelector": {
        "orderId.$": "$.Payload.orderId",
        "customerId.$": "$.Payload.customerId",
        "totalAmount.$": "$.Payload.totalAmount",
        "items.$": "$.Payload.items",
        "paymentStatus.$": "$.Payload.paymentStatus",
        "transactionId.$": "$.Payload.transactionId"
      },
      "Retry": [
        {
          "ErrorEquals": ["States.TaskFailed"],
          "IntervalSeconds": 3,
          "MaxAttempts": 4,
          "BackoffRate": 2,
          "Comment": "Retry transient payment gateway errors with exponential backoff"
        },
        {
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "Next": "Payment Failed",
          "ResultPath": "$.error"
        }
      ],
      "Next": "Wait for Payment Confirmation"
    },
    "Payment Failed": {
      "Type": "Fail",
      "Error": "PaymentFailed",
      "Cause": "Payment processing failed after all retry attempts."
    },
    "Wait for Payment Confirmation": {
      "Type": "Wait",
      "Seconds": 3,
      "Comment": "Simulate real-world payment gateway confirmation delay",
      "Next": "Notify and Record"
    },
    "Notify and Record": {
      "Type": "Parallel",
      "Comment": "Send confirmation email and update analytics simultaneously",
      "Branches": [
        {
          "StartAt": "Send Confirmation",
          "States": {
            "Send Confirmation": {
              "Type": "Task",
              "Resource": "arn:aws:states:::lambda:invoke",
              "Parameters": {
                "FunctionName": "acme-send-confirmation",
                "Payload.$": "$"
              },
              "ResultSelector": {
                "confirmationNumber.$": "$.Payload.confirmationNumber",
                "notificationSent.$": "$.Payload.notificationSent",
                "channel.$": "$.Payload.channel"
              },
              "End": true
            }
          }
        },
        {
          "StartAt": "Update Analytics",
          "States": {
            "Update Analytics": {
              "Type": "Task",
              "Resource": "arn:aws:states:::lambda:invoke",
              "Parameters": {
                "FunctionName": "acme-update-analytics",
                "Payload.$": "$"
              },
              "ResultSelector": {
                "analyticsRecorded.$": "$.Payload.analyticsRecorded",
                "revenueRecorded.$": "$.Payload.revenueRecorded"
              },
              "End": true
            }
          }
        }
      ],
      "ResultPath": "$.parallelResults",
      "Next": "Fulfill Order"
    },
    "Fulfill Order": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "acme-fulfill-order",
        "Payload.$": "$"
      },
      "ResultSelector": {
        "orderId.$": "$.Payload.orderId",
        "fulfillmentId.$": "$.Payload.fulfillmentId",
        "fulfillmentStatus.$": "$.Payload.fulfillmentStatus",
        "estimatedShipDate.$": "$.Payload.estimatedShipDate"
      },
      "Retry": [
        {
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "Next": "Workflow Error",
          "ResultPath": "$.error"
        }
      ],
      "Next": "Order Complete"
    },
    "Order Complete": {
      "Type": "Succeed"
    },
    "Workflow Error": {
      "Type": "Fail",
      "Error": "WorkflowError",
      "Cause": "An unexpected error occurred in the order workflow."
    }
  }
}
```

Click **Design** to confirm the graph renders correctly — you should see the full workflow with all branches.

> **What Is Happening Behind the Scenes?** Let's examine the key ASL patterns:

---

## Part 4: Understanding the ASL Patterns

### Step 9 — Input/Output processing deep dive

Step Functions passes JSON between states. Four parameters control exactly what JSON enters and exits each state:

| Parameter | What it does | Default |
|---|---|---|
| `InputPath` | Filters the state's input — which part of the incoming JSON to pass as input | `$` (whole input) |
| `Parameters` | Constructs a new JSON object to send as the task's actual payload | (use input as-is) |
| `ResultSelector` | Filters/reshapes the raw task result | (use result as-is) |
| `ResultPath` | Where to put the task result in the state's output | `$` (replace whole input) |
| `OutputPath` | Filters the final output before passing to the next state | `$` (whole output) |

> **Why This Matters:** Without `ResultSelector`, Lambda's `invoke` wraps the function's return value under a `Payload` key. If your function returns `{"status": "OK"}`, the Task state result is `{"ExecutedVersion": "...", "Payload": {"status": "OK"}, "StatusCode": 200}`. The `ResultSelector` unwraps it so downstream states see `{"status": "OK"}` directly.

> **AWS Mental Model:** Think of JSON flowing through a pipe with valves. `InputPath` is the inlet valve (which part of the upstream flow enters). `Parameters` reshapes the flow. The task does its work. `ResultSelector` reshapes the output. `ResultPath` decides where in the pipe to insert the result. `OutputPath` is the outlet valve (which part flows downstream).

### Step 10 — Error handling with Retry and Catch

Examine the `Process Payment` state's `Retry` block:

```json
"Retry": [
  {
    "ErrorEquals": ["States.TaskFailed"],
    "IntervalSeconds": 3,
    "MaxAttempts": 4,
    "BackoffRate": 2
  }
]
```

**How this retry works:**
- Attempt 1 fails → wait 3 seconds → attempt 2
- Attempt 2 fails → wait 6 seconds → attempt 3 (3 × 2^1)
- Attempt 3 fails → wait 12 seconds → attempt 4 (3 × 2^2)
- Attempt 4 fails → wait 24 seconds → all retries exhausted
- After all retries fail, the `Catch` block takes over → routes to `Payment Failed`

Total worst-case retry duration: 3 + 6 + 12 + 24 = 45 seconds before giving up.

> **Common Beginner Mistake:** Using `"ErrorEquals": ["States.ALL"]` in a Retry block. This catches everything including non-retryable errors (like missing permissions or bad input). Only retry transient errors. Use `States.TaskFailed` for Lambda exceptions, and specific error types like `Lambda.ServiceException` for infrastructure errors. Reserve `States.ALL` for the final `Catch` as a safety net.

### Step 11 — The Parallel state

The `Notify and Record` state runs two branches simultaneously:

```
[Notify and Record]
   /            \
[Send         [Update
Confirmation]  Analytics]
   \            /
    (both must succeed before proceeding)
```

- Both branches start at the same time (in parallel, not sequentially)
- The Parallel state waits for **all** branches to complete
- If **any** branch fails, the entire Parallel state fails (unless you add Retry/Catch)
- The output of a Parallel state is an **array** containing each branch's output: `[{confirmationResult}, {analyticsResult}]`
- We store this array at `$.parallelResults` using `ResultPath` so the upstream context (orderId, transactionId, etc.) is not overwritten

> **Why This Matters:** In the original `mega-order-handler`, sending the confirmation email and updating analytics happened sequentially. If the analytics call took 500ms, it delayed the email. With Parallel, both happen simultaneously — the order is fully confirmed 500ms faster. At 50,000 orders/day, that's meaningful throughput improvement.

---

## Part 5: Create and Execute the State Machine

### Step 12 — Create the state machine

1. In Workflow Studio, switch to **Config** mode (the third button in the top toolbar, next to Design and Code).
2. In Config mode, set:
   - **State machine name:** `acme-order-fulfillment-workflow`
   - **Type:** Standard
   - **Permissions:** **Create new role** — the console generates an execution role with `lambda:InvokeFunction` for each Lambda in the workflow.
   - **Logging:** Enable logging → **CloudWatch Logs** → select **ALL** log level.
   - **X-Ray tracing:** Enable (check the checkbox).
3. Click **Create** (top-right of Workflow Studio) and confirm the IAM role creation.

> **Why Config mode?** In the current Workflow Studio UI, all state machine settings (name, type, permissions, logging, tracing) live in **Config mode**. Unlike older versions of the console that prompted for settings in a dialog after clicking Create, the current console requires you to set the name in Config mode first. If you click Create without setting a name, the state machine will be created with a default auto-generated name that you cannot rename later.

> **Security Consideration:** Step Functions generates an execution role that only grants `lambda:InvokeFunction` for the **specific Lambda ARNs** referenced in your ASL. If you later add a new Lambda Task and don't update the role, you get `Lambda.AWSLambdaException: AccessDeniedException`. Always update the execution role when adding new Tasks.

> **X-Ray Tracing:** When enabled, Step Functions emits trace data to X-Ray. Each state transition and Lambda invocation is recorded as a span. In X-Ray's service map, you can visualize the entire order workflow as a call graph with timing data — invaluable for finding which step is your latency bottleneck.

### Step 13 — Run the happy path (all items in stock, payment succeeds)

1. On the state machine detail page, click **Start execution**.
2. Paste the following input:

```json
{
  "orderId": "A-20001",
  "customerId": "C-7743",
  "items": [
    {"sku": "SHOE-001", "qty": 1, "price": 89.99},
    {"sku": "SHIRT-042", "qty": 1, "price": 34.50}
  ],
  "totalAmount": 124.49,
  "orderTimestamp": "2026-07-12T11:00:00Z"
}
```

3. Click **Start execution**.
4. Watch the **Graph view**. States should light up: Validate Order → Check Inventory → In Stock? (YES branch) → Process Payment → Wait for Payment Confirmation → Notify and Record → Fulfill Order → Order Complete.

**Validation (happy path):**
- Execution status: **Succeeded**
- The Wait state pauses visibly for ~3 seconds in the graph
- Both branches of the Parallel state complete (green)
- Click **Fulfill Order** → **Output** tab and verify:
```json
{
  "orderId": "A-20001",
  "fulfillmentId": "FULFILL-A-20001",
  "fulfillmentStatus": "QUEUED_FOR_PICKING",
  "estimatedShipDate": "2026-07-13"
}
```

### Step 14 — Run the out-of-stock path

1. Click **Start execution**.
2. Use an item that's out of stock (`HANDBAG-LUX-001` has 0 inventory in our simulation):

```json
{
  "orderId": "A-20002",
  "customerId": "C-8810",
  "items": [
    {"sku": "HANDBAG-LUX-001", "qty": 1, "price": 1299.99}
  ],
  "totalAmount": 1299.99,
  "orderTimestamp": "2026-07-12T11:05:00Z"
}
```

3. Watch the workflow.

**Validation (out of stock):**
- Execution status: **Failed**
- Graph shows: Validate Order → Check Inventory → In Stock? → **Out of Stock** (Fail state)
- Click the **Out of Stock** state → Error: `OutOfStock`
- Process Payment, Notify and Record, Fulfill Order are **never executed** — no charge issued

### Step 15 — Observe Retry behavior for payment

Because the payment Lambda has a 20% random failure rate, run several executions and observe Retry in the execution history:

1. Start 5 executions with valid, in-stock orders (use order IDs A-20003 through A-20007).
2. For each execution, click it → look at the **Events** tab.
3. For executions that had payment retries, you'll see events like:
   - `TaskScheduled` → `TaskStarted` → `TaskFailed` (attempt 1 failed)
   - `TaskScheduled` → `TaskStarted` → `TaskSucceeded` (attempt 2 succeeded)
   - Or multiple failures followed by `States.TaskFailed` → Catch → `Payment Failed`

> **What Is Happening Behind the Scenes?** Step Functions handles all retry logic externally to your Lambda code. Your `acme-process-payment` Lambda does not know it's being retried — it just raises an exception. Step Functions counts the attempts, applies exponential backoff delays, and either retries or routes to the Catch state. This separation of concerns keeps your Lambda code simple while the workflow handles resilience.

---

## Part 6: Advanced State Types

### Step 16 — Understanding the Map State (conceptual + small implementation)

A **Map** state iterates over an array in the input and applies a sub-workflow to each element. For Acme, this is useful for per-item inventory validation or per-item warehouse picking.

**Map state ASL structure:**

```json
"Validate Each Item": {
  "Type": "Map",
  "InputPath": "$.items",
  "ItemsPath": "$",
  "Parameters": {
    "item.$": "$$.Map.Item.Value",
    "orderId.$": "$$.orderId"
  },
  "MaxConcurrency": 5,
  "Iterator": {
    "StartAt": "Validate Single Item",
    "States": {
      "Validate Single Item": {
        "Type": "Task",
        "Resource": "arn:aws:states:::lambda:invoke",
        "Parameters": {
          "FunctionName": "acme-validate-single-item",
          "Payload.$": "$"
        },
        "ResultSelector": {
          "sku.$": "$.Payload.sku",
          "isValid.$": "$.Payload.isValid"
        },
        "End": true
      }
    }
  },
  "ResultPath": "$.itemValidationResults",
  "Next": "All Items Valid?"
}
```

**Key Map state parameters:**

| Parameter | Purpose |
|---|---|
| `ItemsPath` | Which array in the input to iterate over |
| `MaxConcurrency` | How many iterations run in parallel (0 = unlimited) |
| `Iterator` | The sub-state-machine applied to each element |
| `$$.Map.Item.Value` | The current element being processed |
| `$$.Map.Item.Index` | The 0-based index of the current element |
| `ResultPath` | Where to store the array of all iteration results |

> **AWS Mental Model:** Map state is like a `parallel for loop` — it spins up a sub-workflow for each element in an array, runs them (up to MaxConcurrency at a time), collects all results into an output array, and then continues to the next state. It's substantially more efficient than chaining individual Task states for N items when N is variable.

### Step 17 — Service Integration Patterns

Step Functions can call AWS services in two ways:

**1. SDK Integrations** (via `arn:aws:states:::aws-sdk:serviceName:apiAction`)
- Covers 200+ AWS services and 10,000+ API actions
- No native Step Functions support needed — if the SDK has an action, Step Functions can call it
- Example: calling DynamoDB PutItem directly without a Lambda wrapper

```json
"Save to DynamoDB": {
  "Type": "Task",
  "Resource": "arn:aws:states:::dynamodb:putItem",
  "Parameters": {
    "TableName": "acme-orders",
    "Item": {
      "orderId": {"S.$": "$.orderId"},
      "status": {"S": "FULFILLED"},
      "timestamp": {"S.$": "$$.Execution.StartTime"}
    }
  },
  "Next": "Order Complete"
}
```

**2. Optimized Integrations** (for a subset of services)
- Deep Step Functions-specific integration (e.g., `arn:aws:states:::sqs:sendMessage.waitForTaskToken`)
- Enables the **callback pattern** (`.waitForTaskToken`) — pause execution until an external system sends a heartbeat

> **Why This Matters:** The SDK integration approach means you often don't need a "glue" Lambda function just to call DynamoDB or SQS. This reduces cost (no Lambda execution), reduces latency, and simplifies the architecture.

---

## Part 7: Execution History and X-Ray

### Step 18 — Explore the execution history

1. Go to **State machines** → `acme-order-fulfillment-workflow`.
2. Under **Executions**, click any completed execution.
3. On the **Events** tab, scroll through the event history. For a successful execution you see:
   - `ExecutionStarted`
   - `TaskScheduled`, `TaskStarted`, `TaskSucceeded` for each Lambda call
   - `WaitStateEntered`, `WaitStateExited` for the Wait state
   - `ParallelStateEntered`, `BranchSucceeded` (×2), `ParallelStateSucceeded`
   - `ExecutionSucceeded`

4. Click any `TaskSucceeded` event — you can see the **Input** and **Output** JSON for that specific state in that specific execution.

**Validation:** Find the Parallel state's output event. The output is an array `[{confirmationResult}, {analyticsResult}]` — the results from both branches.

### Step 19 — View X-Ray service map

1. Console search → **X-Ray** (or find it under CloudWatch → X-Ray traces).
2. Left menu → **Service map**.
3. Set the time range to **Last 30 minutes**.
4. You should see a graph showing: Step Functions state machine → Lambda function nodes → connections between them.
5. Click any Lambda node to see P50/P90/P99 latency.
6. Left menu → **Traces** → click an individual trace to see the full timeline waterfall showing each state's duration.

> **Why This Matters:** X-Ray reveals the actual latency distribution of each step. If `acme-check-inventory` has a P99 of 4 seconds while everything else is under 100ms, that's your optimization target. Without distributed tracing, this is nearly impossible to diagnose from Lambda metrics alone.

---

## Challenges

> Attempt these challenges on your own before looking at the solutions in `08-solutions.md`.

### Challenge 1: Human Approval with Callback Pattern

The Acme finance team requires manual approval for orders over $5,000 before payment is processed. The workflow must **pause** after inventory check, wait for a human to approve or reject via an API call, then resume.

**Your task:**

1. Add a new Lambda function `acme-approval-notifier` that sends an approval request to SQS (or just logs the task token for simulation purposes)
2. Modify the ASL to insert a new state between `Check Inventory` and `Process Payment`:
   ```
   Check Inventory → High Value? → [if > $5000] → Request Approval (waitForTaskToken) → Approval Decision? → Process Payment
                                 → [if ≤ $5000] → Process Payment
   ```
3. The `Request Approval` state should:
   - Use the `arn:aws:states:::sqs:sendMessage.waitForTaskToken` resource (optimized SQS integration)
   - Send a message to a new SQS queue `acme-approval-requests` containing the task token and order details
   - Use `.waitForTaskToken` so the execution pauses
4. Create a second Lambda function `acme-approve-order` that:
   - Reads the task token from SQS
   - Calls `StepFunctions:SendTaskSuccess` to resume the execution (or `SendTaskFailure` to reject)
5. Test with an order over $5,000 and verify the execution pauses

**Key concepts to research:**
- `$$.Task.Token` — how to pass the task token in Parameters
- `arn:aws:states:::sqs:sendMessage.waitForTaskToken` resource ARN syntax
- `SendTaskSuccess` and `SendTaskFailure` API calls
- The execution role needs `sqs:SendMessage` on the approval queue

---

### Challenge 2: Per-Item Validation with a Map State

The product team wants individual item-level validation in the order workflow. Each item in the order should be validated independently (check SKU format, price bounds, quantity limits) so the error message can say exactly which item failed and why.

**Your task:**

1. Create a Lambda function `acme-validate-item` (Python 3.12) that:
   - Accepts a single item: `{"sku": "...", "qty": N, "price": N.NN, "orderId": "..."}`
   - Returns `{"sku": "...", "qty": N, "price": N.NN, "isValid": bool, "validationMessage": "..."}`
   - Validates: SKU must match pattern `[A-Z]+-\d+` or `[A-Z]+-[A-Z]+-\d+`, qty must be 1-100, price must be > 0 and < 10000
2. Add a `Validate Items` Map state to the workflow (insert it between `Validate Order` and `Check Inventory`)
3. Configure the Map state to:
   - Iterate over `$.items`
   - Run up to 5 items in parallel (`MaxConcurrency: 5`)
   - Store all results in `$.itemValidationResults`
4. Add a Choice state after the Map that checks if any item failed validation:
   - If all items valid → continue to Check Inventory
   - If any item invalid → route to a new `Item Validation Failed` Fail state
5. Test with a mixed order containing one valid item and one item with an invalid SKU format

**Hints:**
- Use `$$.Map.Item.Value` to access the current array element in Parameters
- The `orderId` context needs to be passed to each item via `$$.Execution.Input.orderId` (context object)
- For the "any item failed" check: Lambda's `reduce` or a simple scan function is cleaner than complex ASL conditions

---

## Key Takeaways

1. **Step Functions orchestrates; Lambda executes.** The state machine handles flow control, error handling, and retry logic — your Lambda functions stay focused on business logic.
2. **Standard = auditable, long-running.** Express = high-volume, short-duration, cost-optimized.
3. **Every state type has a purpose:** Task (call services), Choice (branch), Wait (delay), Parallel (concurrent), Map (iterate), Pass (transform), Succeed/Fail (terminal states).
4. **Retry + Catch** handles transient errors externally — your Lambda code doesn't need retry loops.
5. **Exponential backoff** (BackoffRate > 1) prevents overwhelming a struggling downstream service during recovery.
6. **ResultSelector** unwraps Lambda's `Payload` wrapper so downstream states see clean JSON.
7. **Parallel state** runs branches simultaneously — improves throughput, both branches must succeed.
8. **X-Ray tracing** reveals per-state latency distributions — essential for finding bottlenecks.
9. **SDK integrations** let Step Functions call AWS services (DynamoDB, SQS, etc.) without Lambda glue code.
10. **Callback pattern** (`.waitForTaskToken`) enables human-in-the-loop workflows that pause for external signals.

---

## Cleanup Instructions

Delete in this order:

1. **State machine:**
   - Step Functions → State machines → select `acme-order-fulfillment-workflow` → Delete → confirm

2. **Step Functions execution role:**
   - IAM → Roles → search for the auto-created role (starts with `StepFunctions-acme-order-fulfillment-`) → Delete

3. **Lambda functions** (delete all `acme-*` functions created in this lab):
   - Lambda → select each → Actions → Delete

4. **Lambda execution roles:**
   - IAM → Roles → search `acme-validate-order`, `acme-check-inventory`, etc. → Delete each

5. **CloudWatch Log groups:**
   - CloudWatch → Logs → Log groups → delete all `/aws/lambda/acme-*` and `/aws/states/acme-*` groups

6. **X-Ray traces:** No cleanup needed — X-Ray trace data expires automatically after 30 days.

**Validation:** Step Functions shows no `acme-order-fulfillment-workflow` state machine. Lambda console shows no `acme-*` functions.
