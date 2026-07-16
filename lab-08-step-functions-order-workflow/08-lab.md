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

> ## ⚠️ IMPORTANT: Shared Account Environment
>
> You are working in a **shared AWS account** with other students. To avoid resource name conflicts and ensure isolation:
>
> - **Use your unique learner ID as a prefix for all resource names.** If your learner ID is `01`, prefix all Step Functions state machines with `s01-` (e.g., `s01-acme-order-workflow`).
> - **Tag all resources** with `LearnerId = studentNN` (e.g., `LearnerId = student01`) where tagging is supported.
> - **Do not modify or execute state machines created by other students.**
> - **Always verify the state machine name before starting executions.**
>
> **Example naming:**
> - State Machine: `s01-acme-order-workflow` (instead of `acme-order-workflow`)
> - Lambda functions: `s01-acme-validate-order`, `s01-acme-check-inventory`, `s01-acme-process-payment`
> - DynamoDB tables: `s01-AcmeOrders`, `s01-AcmeInventory`

---

## Part 1: Standard vs. Express Workflows — The Decision

Before building anything, understand the two workflow types. This is a frequently tested AWS concept.

| Feature | Standard Workflow | Express Workflow |
|---|---|---|
| **Max duration** | 1 year | 5 minutes |
| **Execution model** | Exactly-once per state | At-least-once (asynchronous Express — the default and the pattern used in this lab; synchronous Express is at-most-once) |
| **Execution history** | Full visual history in console (retained 90 days after an execution closes) | CloudWatch Logs only |
| **Pricing** | Per state transition | Per execution + per GB-second duration |
| **Use case** | Order processing, approval flows, long-running jobs | High-volume event processing, IoT, streaming |
| **Audit** | Full audit trail built-in | Must enable CloudWatch Logs for audit |
| **Concurrency** | Up to 1 million open (concurrently running) executions per account/Region | Up to ~100,000 executions/second start rate |

> **Quotas change over time.** The figures above reflect AWS's currently published Step Functions quotas at the time this lab was written. Quotas (especially throughput and concurrency numbers) are exactly the kind of detail AWS revises — before relying on a specific number for an assessment or a production design decision, check the current [Step Functions service quotas page](https://docs.aws.amazon.com/step-functions/latest/dg/service-quotas.html).

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
3. Choose **Create from blank** (the blank-canvas option, as opposed to picking a starter template from the gallery). If the console prompts you for a name at this point, you can enter one now and choose **Continue** — you'll confirm (or change) the name, type, and every other setting explicitly in **Config** mode before you do the final **Create** in Step 12.
4. You land in **Workflow Studio**, which opens in **Design** mode by default.

> **Instructor note:** Workflow Studio's exact template-picker wording has changed across console releases. Confirm the current label (`Create from blank` at time of writing) before delivery — the underlying steps (land in Design mode, build the graph, finish in Config mode) have stayed stable even when button text has moved.

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
          "ErrorEquals": ["Lambda.ClientExecutionTimeoutException", "Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"],
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
          "ErrorEquals": ["Lambda.ClientExecutionTimeoutException", "Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"],
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
          "ErrorEquals": ["Lambda.ClientExecutionTimeoutException", "Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2,
          "Comment": "Retry Lambda service/infrastructure errors"
        },
        {
          "ErrorEquals": ["States.TaskFailed"],
          "IntervalSeconds": 3,
          "MaxAttempts": 4,
          "BackoffRate": 2,
          "Comment": "Retry the simulated payment-gateway exception (and any other Lambda error not already matched above) with a more patient backoff"
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
          "ErrorEquals": ["Lambda.ClientExecutionTimeoutException", "Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"],
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

Examine the `Process Payment` state's `Retry` block — it has **two** retriers, and the order they're listed in matters:

```json
"Retry": [
  {
    "ErrorEquals": ["Lambda.ClientExecutionTimeoutException", "Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"],
    "IntervalSeconds": 2,
    "MaxAttempts": 3,
    "BackoffRate": 2
  },
  {
    "ErrorEquals": ["States.TaskFailed"],
    "IntervalSeconds": 3,
    "MaxAttempts": 4,
    "BackoffRate": 2
  }
]
```

**Why the order matters:** Step Functions scans a state's retriers **in the order they appear** and uses the first one whose `ErrorEquals` list contains the reported error name. `States.TaskFailed` is a predefined wildcard — AWS's documentation defines it as matching "any known error name except `States.Timeout`." That means it would also match `Lambda.ServiceException`, `Lambda.AWSLambdaException`, and every other Lambda error name. If the `States.TaskFailed` retrier were listed *first*, the more specific Lambda-infrastructure retrier below it would never fire — it would be unreachable, dead configuration. Listing the specific error names first and the wildcard last (the same pattern AWS uses in its own documented examples) guarantees each retrier only handles the errors it's meant to.

The `acme-process-payment` Lambda's simulated `raise Exception(...)` doesn't match any of the specific `Lambda.*` names in the first retrier (Lambda reports unhandled code exceptions as `Lambda.Unknown`), so it falls through to the second retrier, where `States.TaskFailed` catches it.

**How the second retrier's backoff works** (this is the one that actually fires for the simulated payment-gateway exception):
- Attempt 1 fails → wait 3 seconds → attempt 2
- Attempt 2 fails → wait 6 seconds → attempt 3 (3 × 2^1)
- Attempt 3 fails → wait 12 seconds → attempt 4 (3 × 2^2)
- Attempt 4 fails → wait 24 seconds → all retries exhausted
- After all retries fail, the `Catch` block takes over → routes to `Payment Failed`

Total worst-case retry duration: 3 + 6 + 12 + 24 = 45 seconds before giving up.

> **Common Beginner Mistake:** Using `"ErrorEquals": ["States.ALL"]` in a Retry block. This catches everything including non-retryable errors (like missing permissions or bad input). Only retry transient errors, and reserve `States.ALL` for the final `Catch` as a safety net. A related, subtler mistake: putting a wildcard retrier (`States.TaskFailed` or `States.ALL`) *before* a more specific one in the same `Retry` array. Because Step Functions stops at the first matching retrier, the wildcard will "steal" every error the specific retrier was meant to handle. Always list specific error names first and wildcards last.

> **Instructor verification note:** AWS's Workflow Studio pre-populates a default retrier automatically when you drag an **AWS Lambda Invoke** action onto the canvas (per AWS's Step Functions documentation: *"Lambda Invoke has one retrier configured by default"*). This lab bypasses that by pasting ASL directly in Code mode (Step 8), so the console default never actually appears on screen — but if you demo the drag-and-drop flow separately, expect a pre-filled retrier close to AWS's published best-practice example (`Lambda.ServiceException`, `Lambda.AWSLambdaException`, `Lambda.SdkClientException`, `Lambda.ClientExecutionTimeoutException`; 2s interval; documented best-practice guidance uses 6 max attempts). Spot-check the exact pre-filled values in the console before citing a specific number to students, since AWS does not commit to console-default values as a stable API contract.

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

> **Why Config mode?** Workflow Studio has exactly three modes — **Design**, **Code**, and **Config** — and per AWS's own documentation, "Details" in Config mode is where you "set the workflow **name** and **type**. Note that both **cannot** be changed after you create the state machine." Permissions (execution role), Logging, and X-Ray tracing (under "Additional configuration") also live in Config mode. This is unlike some older Workflow Studio releases, which prompted for these settings in a separate post-Create dialog — but regardless of console era, the rule has stayed the same: **name and type are locked in permanently the moment you click Create**, so set them deliberately before that click. If you click Create while the name field still holds its auto-generated placeholder (something like `MyStateMachine`), that placeholder becomes the permanent, unchangeable name.

> **Security Consideration:** Step Functions generates an execution role that only grants `lambda:InvokeFunction` for the **specific Lambda ARNs** referenced in your ASL. If you later add a new Lambda Task and don't update the role, you get `Lambda.AWSLambdaException: AccessDeniedException`. Always update the execution role when adding new Tasks.

> **X-Ray Tracing:** When enabled, Step Functions emits trace data to X-Ray. Each state transition and Lambda invocation is recorded as a span. In the X-Ray trace map (Step 19), you can visualize the entire order workflow as a call graph with timing data — invaluable for finding which step is your latency bottleneck.

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

> **Iterator is legacy — use ItemProcessor.** Older Step Functions examples (and some existing state machines) use a field called `Iterator` to hold the Map state's sub-workflow. AWS's Amazon States Language documentation now states plainly: *"The `ItemProcessor` field replaces the now deprecated `Iterator` field. Although you can continue to include `Map` states that use the `Iterator` field, we highly recommend that you replace this field with `ItemProcessor`."* The same page deprecates the Map-level `Parameters` field in favor of `ItemSelector` for the same reason. The example below uses the current, recommended fields.

**Map state ASL structure:**

```json
"Validate Each Item": {
  "Type": "Map",
  "InputPath": "$.items",
  "ItemsPath": "$",
  "ItemSelector": {
    "item.$": "$$.Map.Item.Value",
    "orderId.$": "$$.Execution.Input.orderId"
  },
  "MaxConcurrency": 5,
  "ItemProcessor": {
    "ProcessorConfig": {
      "Mode": "INLINE"
    },
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

Two details worth calling out in that snippet:
- **`ItemSelector`, not `Parameters`.** Inside a `Map` state specifically, `Parameters` is the deprecated field; `ItemSelector` is its replacement (this is the one place in this whole lab where `Parameters` is *not* the right field — every `Task` state's `Parameters` elsewhere in this workflow, used to build the Lambda `Payload`, is unaffected and still current).
- **`$$.Execution.Input.orderId`, not `$$.orderId`.** The Context object (`$$`) has no top-level `orderId` field — its top-level nodes are `Execution`, `State`, `StateMachine`, `Task`, and (inside a Map iteration) `Map`. To reach back to the original execution's input from inside a Map iteration, go through `$$.Execution.Input.<field>`.

**Key Map state parameters:**

| Parameter | Purpose |
|---|---|
| `ItemsPath` | Which array in the input to iterate over |
| `ItemSelector` | Reshapes what each iteration receives as input — this is where you read from the Context object (`$$`) to pull in order-level data alongside the current array element |
| `MaxConcurrency` | How many iterations run in parallel (0 = unlimited) |
| `ItemProcessor` | The sub-state-machine applied to each element, plus a `ProcessorConfig.Mode` of `INLINE` (default — used here) or `DISTRIBUTED` |
| `$$.Map.Item.Value` | The current element being processed |
| `$$.Map.Item.Index` | The 0-based index of the current element |
| `ResultPath` | Where to store the array of all iteration results |

> **Inline vs. Distributed — don't mix these up.** `ProcessorConfig.Mode: "INLINE"` (the default, and what we use here) runs each iteration inside the *same* execution, capped at 40 concurrent iterations, with all iteration history rolled into the parent execution's history. `DISTRIBUTED` mode is a separate, more advanced feature: each iteration runs as its own **child workflow execution**, supports up to 10,000 parallel children, and can read items straight from an S3 file instead of only an inline JSON array. Distributed mode is the right tool for very large or very high-concurrency fan-outs, but it changes how you monitor and pay for the workflow — it is not a drop-in swap for Inline mode, and this lab does not use it.

> **AWS Mental Model:** Map state is like a `parallel for loop` — it spins up a sub-workflow for each element in an array, runs them (up to MaxConcurrency at a time), collects all results into an output array, and then continues to the next state. It's substantially more efficient than chaining individual Task states for N items when N is variable.

### Step 17 — Service Integration Patterns

Step Functions can call AWS services in two ways. Getting this pair right matters for the DynamoDB example specifically, so read both bullets before the code:

**1. AWS SDK Integrations** (via `arn:aws:states:::aws-sdk:serviceName:apiAction`)
- Covers 200+ AWS services and 10,000+ API actions — this is the generic path: if an action exists in the AWS SDK, Step Functions can call it, even when AWS hasn't built dedicated ("optimized") support for that specific action
- Example: DynamoDB's `DescribeTable` action has **no** optimized integration (see below), so to call it without a Lambda wrapper you go through the generic SDK integration

```json
"Check Orders Table": {
  "Type": "Task",
  "Resource": "arn:aws:states:::aws-sdk:dynamodb:describeTable",
  "Parameters": {
    "TableName": "acme-orders"
  },
  "ResultSelector": {
    "tableStatus.$": "$.Table.TableStatus"
  },
  "Next": "Order Complete"
}
```

**2. Optimized Integrations** (for a subset of services and actions)
- A dedicated, Step Functions-specific ARN shape with no `aws-sdk:` prefix — e.g. `arn:aws:states:::dynamodb:putItem` or `arn:aws:states:::sqs:sendMessage`
- DynamoDB's optimized integration covers exactly four actions: `GetItem`, `PutItem`, `UpdateItem`, and `DeleteItem` (lowercase-first in the ARN: `getItem`, `putItem`, `updateItem`, `deleteItem`). Anything else on DynamoDB — like `DescribeTable` above — falls back to the generic SDK integration
- Example: writing the completed order straight to DynamoDB, no Lambda wrapper needed

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

- Some optimized integrations also support the **callback pattern** — a `.waitForTaskToken` suffix on the resource ARN (e.g. `arn:aws:states:::sqs:sendMessage.waitForTaskToken`) that pauses the execution until an external system calls `SendTaskSuccess`/`SendTaskFailure` with the task token. See Challenge 1 for a full working example.

> **Why This Matters:** Both integration styles mean you often don't need a "glue" Lambda function just to call DynamoDB or SQS — this reduces cost (no Lambda execution), reduces latency, and simplifies the architecture. Reach for the optimized integration first when one exists for the exact action you need; fall back to the generic `aws-sdk:` integration for everything else.

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

### Step 19 — View the X-Ray trace map

AWS's X-Ray functionality now lives primarily inside the **CloudWatch console** — AWS's own documentation states that the standalone X-Ray console "is no longer being developed" and that the X-Ray service map and CloudWatch ServiceLens map "have been combined into the X-Ray trace map within the Amazon CloudWatch console." Use the CloudWatch path below; the older, standalone X-Ray console still works if you land on it, but with different labels (noted below).

1. Console search → **CloudWatch**, then confirm the region is **us-west-2**.
2. Left navigation → **X-Ray traces** section → **Trace Map**.
3. Set the time range to **Last 30 minutes**.
4. You should see a graph showing: Step Functions state machine → Lambda function nodes → connections between them.
5. Click any Lambda node to see latency and request-count details.
6. Left navigation → **X-Ray traces** → **Traces** → click an individual trace to see the full timeline waterfall showing each state's duration.

> **If you land on the standalone X-Ray console instead** (e.g., by searching "X-Ray" directly): the equivalent items are labeled **Service Map** and **Traces** in its left navigation. The data is the same; only the console and some labels differ. Since AWS is actively steering users toward the CloudWatch experience, use the CloudWatch path above for this lab, and treat the standalone console as a fallback.

> **Why This Matters:** X-Ray reveals the actual latency distribution of each step. If `acme-check-inventory` has a P99 of 4 seconds while everything else is under 100ms, that's your optimization target. Without distributed tracing, this is nearly impossible to diagnose from Lambda metrics alone.

> **Instructor verification note:** Console navigation for X-Ray/CloudWatch has been reorganized more than once. Confirm the exact left-navigation wording ("Trace Map" under "X-Ray traces") in your delivery account before class.

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
- Use `$$.Map.Item.Value` to access the current array element in the Map state's `ItemSelector` (the modern replacement for the deprecated Map-level `Parameters` field — see Step 16)
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
   - IAM → Roles → search `acme-order-fulfillment-workflow` (the console names the auto-created role something like `StepFunctions-acme-order-fulfillment-workflow-role-<random-suffix>` — searching on the state machine name reliably finds it regardless of the exact suffix) → Delete

3. **Lambda functions** (delete all `acme-*` functions created in this lab):
   - Lambda → select each → Actions → Delete

4. **Lambda execution roles:**
   - IAM → Roles → search `acme-validate-order`, `acme-check-inventory`, etc. → Delete each

5. **CloudWatch Log groups:**
   - CloudWatch → Logs → Log groups → delete all `/aws/lambda/acme-*` groups (one per Lambda function).
   - Also delete the state machine's log group. Per AWS's guidance, a log group created from the Step Functions console is suggested with a name prefixed `/aws/vendedlogs/states/...` (not `/aws/states/...`) — but since Step 12 didn't have you type an exact name, search **Log groups** for `acme-order-fulfillment` (substring search) to find whatever name the console actually assigned, and delete it.

6. **X-Ray traces:** No cleanup needed — X-Ray trace data expires automatically after 30 days.

**Validation:** Step Functions shows no `acme-order-fulfillment-workflow` state machine. Lambda console shows no `acme-*` functions.
