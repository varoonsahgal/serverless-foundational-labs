# Lab 09: Full Observability with Amazon CloudWatch

## Estimated Duration

~90 minutes

## Scenario / Business Context

**Acme Retail** just promoted four new Lambda-based microservices to production: an order intake API, a payment processor, an inventory checker, and a notification service. Two weeks in, the operations team has zero visibility into what's happening. The only alert they receive is from the customer support queue when orders fail. Last Tuesday, the payment processor silently failed for 47 minutes — 312 orders were accepted by the intake API and confirmed to customers, but never charged. Finance discovered the problem when the daily reconciliation report showed a $48,000 discrepancy.

The engineering team's mandate: **instrument everything**. Before the next deploy, every microservice must have log groups with retention policies, custom business metrics (orders processed, order values, error rates), dashboards, metric alarms wired to SNS, and Logs Insights queries that let anyone on-call quickly diagnose what went wrong and when.

Your job is to build out this entire observability stack for the order processing Lambda, `acme-order-processor`.

> **AWS Mental Model — The Observability Trinity:**
> - **Logs** = the detailed transcript of what happened. "Order A-10427 failed at payment step: card declined." Answers *what* and *why*.
> - **Metrics** = the numeric time series gauges. Error rate: 12%. Avg latency: 340ms. Answers *how much* and *how fast*.
> - **Traces** = the distributed call graph across services. Shows *where* time was spent across Lambda → DynamoDB → Payment API. Answers *which service* caused the latency.
> CloudWatch handles Logs and Metrics. X-Ray handles Traces. Together they form a complete observability picture.

## Learning Objectives

By the end of this lab you will be able to:

1. Create a **Lambda function** that emits structured logs and **custom CloudWatch metrics** using `boto3`.
2. Navigate **CloudWatch Log groups** and **log streams** and set retention policies.
3. Write 4+ complex **CloudWatch Logs Insights** queries for error analysis and performance profiling.
4. Create **CloudWatch Alarms** (simple and composite) on built-in and custom metrics.
5. Create a **Metric Filter** to count ERROR occurrences from log content.
6. Build a multi-widget **CloudWatch Dashboard**.
7. Enable **Anomaly Detection** on a metric.
8. Wire alarms to **SNS** for email notification.
9. Explain **Contributor Insights**, **ServiceLens**, and **Log Subscriptions** (overview).

## AWS Services Used

- **Amazon CloudWatch** (Logs, Log Insights, Metrics, Alarms, Dashboards, Anomaly Detection)
- **AWS Lambda** — the monitored function
- **Amazon SNS** — alarm notifications
- **AWS IAM** — Lambda execution role with CloudWatch permissions
- **AWS X-Ray** — distributed tracing (referenced via ServiceLens)

## Prerequisites

- AWS account with an IAM user (not root) with CloudWatch, Lambda, SNS, and IAM permissions.
- Working in **US West (Oregon) `us-west-2`**. Confirm the region before every step.


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

## Part 1: Create the Instrumented Lambda Function

### Step 1 — Create `acme-order-processor`

1. Navigate to **Lambda** → confirm region is **us-west-2**.
2. **Create function** → **Author from scratch**.
3. **Function name:** `acme-order-processor`
4. **Runtime:** **Python 3.12**
5. Leave **Create a new role with basic Lambda permissions** selected.
6. Click **Create function**.
7. Replace `lambda_function.py` with the following instrumented code:

```python
import json
import logging
import random
import time
import boto3
from datetime import datetime, timezone

# ─────────────────────────────────────────────
# Setup logger — Lambda automatically routes
# both print() and logger output to CloudWatch
# ─────────────────────────────────────────────
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# CloudWatch client for publishing custom metrics
cloudwatch = boto3.client('cloudwatch', region_name='us-west-2')

METRIC_NAMESPACE = 'Acme/OrderProcessing'

def emit_metric(metric_name, value, unit='Count', dimensions=None):
    """Emit a custom metric to CloudWatch."""
    if dimensions is None:
        dimensions = [{'Name': 'Service', 'Value': 'OrderProcessor'}]
    try:
        cloudwatch.put_metric_data(
            Namespace=METRIC_NAMESPACE,
            MetricData=[{
                'MetricName': metric_name,
                'Value': value,
                'Unit': unit,
                'Dimensions': dimensions,
                'Timestamp': datetime.now(tz=timezone.utc)
            }]
        )
    except Exception as e:
        # Never let metric emission crash the main function
        logger.warning(f"Failed to emit metric {metric_name}: {e}")

def lambda_handler(event, context):
    start_time = time.time()
    order_id = event.get('orderId', 'UNKNOWN')
    customer_id = event.get('customerId', 'UNKNOWN')
    amount = event.get('totalAmount', 0)
    order_type = event.get('orderType', 'STANDARD')
    fail = event.get('fail', False)
    fail_type = event.get('failType', 'generic')

    # ─── Structured log: one JSON line per invocation
    logger.info(json.dumps({
        "event": "order_received",
        "orderId": order_id,
        "customerId": customer_id,
        "amount": amount,
        "orderType": order_type,
        "requestId": context.aws_request_id
    }))

    try:
        # Simulate variable processing time (50–300ms base)
        processing_ms = random.randint(50, 300)
        time.sleep(processing_ms / 1000)

        if fail:
            if fail_type == 'payment':
                raise ValueError(f"PaymentProcessingError: card declined for customer {customer_id}")
            elif fail_type == 'inventory':
                raise RuntimeError(f"InventoryServiceUnavailable: could not reach inventory service")
            else:
                raise Exception(f"UnexpectedError: simulated failure for order {order_id}")

        # Success path
        elapsed_ms = (time.time() - start_time) * 1000

        logger.info(json.dumps({
            "event": "order_processed",
            "orderId": order_id,
            "customerId": customer_id,
            "amount": amount,
            "processingMs": round(elapsed_ms, 2),
            "status": "SUCCESS"
        }))

        # ─── Custom metrics: business KPIs
        emit_metric('OrdersProcessed', 1)
        emit_metric('OrderValue', amount, unit='None')
        emit_metric('ProcessingLatencyMs', elapsed_ms, unit='Milliseconds')

        if order_type == 'EXPRESS':
            emit_metric('ExpressOrdersProcessed', 1,
                        dimensions=[{'Name': 'Service', 'Value': 'OrderProcessor'},
                                    {'Name': 'OrderType', 'Value': 'EXPRESS'}])

        return {
            'statusCode': 200,
            'orderId': order_id,
            'status': 'PROCESSED',
            'processingMs': round(elapsed_ms, 2)
        }

    except Exception as e:
        elapsed_ms = (time.time() - start_time) * 1000
        error_type = type(e).__name__

        logger.error(json.dumps({
            "event": "order_failed",
            "orderId": order_id,
            "customerId": customer_id,
            "amount": amount,
            "errorType": error_type,
            "errorMessage": str(e),
            "processingMs": round(elapsed_ms, 2),
            "status": "FAILED"
        }))

        # Custom failure metrics
        emit_metric('OrdersFailed', 1)
        emit_metric('OrderFailureByType', 1,
                    dimensions=[{'Name': 'Service', 'Value': 'OrderProcessor'},
                                {'Name': 'ErrorType', 'Value': error_type}])

        raise  # Re-raise so Lambda marks invocation as failed (increments Errors metric)
```

8. Click **Deploy**.

### Step 2 — Grant the Lambda permission to emit custom metrics

The auto-created execution role only grants CloudWatch Logs permissions. We need to add `cloudwatch:PutMetricData`:

1. On the function page → **Configuration** → **Permissions** → click the **execution role** link.
2. In IAM → **Add permissions** → **Create inline policy**.
3. Paste this JSON:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPutCustomMetrics",
      "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "cloudwatch:namespace": "Acme/OrderProcessing"
        }
      }
    }
  ]
}
```

4. **Policy name:** `acme-order-processor-metrics`
5. Click **Create policy**

> **Security Consideration:** The `Condition` block restricts `PutMetricData` to only the `Acme/OrderProcessing` namespace. Without this restriction, the Lambda could publish metrics under any namespace (including `AWS/Lambda`, potentially polluting system metrics). The condition is a least-privilege best practice for `cloudwatch:PutMetricData`.

### Step 3 — Generate test data

You need diverse log data to make the Logs Insights queries interesting.

1. Lambda → `acme-order-processor` → **Test** tab.

Create and run these test events (create each as a named event, run it 2-3 times):

**Event: `success-standard`**
```json
{"orderId": "A-30001", "customerId": "C-1001", "totalAmount": 89.99, "orderType": "STANDARD"}
```
Run **5 times**.

**Event: `success-express`**
```json
{"orderId": "A-30002", "customerId": "C-1002", "totalAmount": 249.00, "orderType": "EXPRESS"}
```
Run **3 times**.

**Event: `success-high-value`**
```json
{"orderId": "A-30003", "customerId": "C-1003", "totalAmount": 4500.00, "orderType": "STANDARD"}
```
Run **2 times**.

**Event: `fail-payment`**
```json
{"orderId": "A-30010", "customerId": "C-2001", "totalAmount": 159.00, "orderType": "STANDARD", "fail": true, "failType": "payment"}
```
Run **4 times**.

**Event: `fail-inventory`**
```json
{"orderId": "A-30011", "customerId": "C-2002", "totalAmount": 39.99, "orderType": "STANDARD", "fail": true, "failType": "inventory"}
```
Run **2 times**.

**Total: 16 invocations, 6 failures, 10 successes.**

> **Why This Matters:** Metrics and logs don't appear until the function runs. By generating a realistic mix of successes and failures — including different error types — you now have real telemetry to query and alarm on, mirroring what an on-call engineer would see during an incident.

---

## Part 2: CloudWatch Logs

### Step 4 — Navigate Log Groups and Streams

1. Console search → **CloudWatch** → confirm region **us-west-2**.
2. Left menu → **Logs** → **Log groups**.
3. Find and click **`/aws/lambda/acme-order-processor`**.

> **Log Group vs. Log Stream:**
> - A **log group** is the container for all logs from one source. Think of it as a filing cabinet labeled "acme-order-processor."
> - A **log stream** is one sequence of events from one Lambda execution environment instance. Think of it as one file in that cabinet. A busy Lambda has many streams (one per cold start / execution environment).

4. Click the most recent **log stream**. Scroll through and find:
   - Structured JSON lines with `"event": "order_received"` and `"event": "order_processed"`
   - Structured JSON error lines with `"event": "order_failed"` and the error messages
   - Lambda's own metadata lines (START, END, REPORT with duration and memory)

> **Common Beginner Mistake:** Looking for logs in CloudTrail instead of CloudWatch. **CloudWatch Logs** = your application's `print()` and `logger.info()` output. **AWS CloudTrail** = "who called which AWS API call, when, from where" — a governance/audit trail. They are entirely separate services.

### Step 5 — Set Log Retention

1. On the log group page, click **Actions** → **Edit retention setting(s)**.
2. Set retention to **30 days**.
3. Click **Save**.

**Validation:** The log group's Retention column shows **30 days**.

> **Cost Awareness:** CloudWatch charges for log ingestion ($0.50/GB ingested) and log storage ($0.03/GB/month). A busy Lambda generating 1 GB/month of logs costs $0.03/month to store — not much. But leaving 50 log groups at **Never expire** across a production account over years adds up. Set retention appropriate to your debugging and compliance needs. 30 days is common for debugging; 90 days for compliance.

---

## Part 3: CloudWatch Logs Insights Queries

Logs Insights is a powerful SQL-like query engine built into CloudWatch. Use it instead of manually scrolling log streams.

### Step 6 — Run the core Logs Insights queries

1. CloudWatch → **Logs** → **Logs Insights**.
2. **Select log group(s):** `/aws/lambda/acme-order-processor`.
3. Set the time range to **Last 30 minutes** (adjust to **Last 1 hour** if you've been working slowly).
4. Run each query below, one at a time.

---

**Query 1: Overview — all structured log events**
```
fields @timestamp, event, orderId, customerId, amount, status, errorMessage
| filter ispresent(event)
| sort @timestamp desc
| limit 50
```
This shows all your custom log events in reverse chronological order.

**Expected output:** Rows with `event`, `orderId`, `customerId`, `amount`, `status` columns showing your test data.

---

**Query 2: Error analysis — all failures with error details**
```
fields @timestamp, orderId, customerId, errorType, errorMessage, processingMs
| filter event = "order_failed"
| sort @timestamp desc
```
This finds every failed order and shows exactly what went wrong.

**Expected output:** 6 rows (4 payment failures + 2 inventory failures). Columns show the `errorType` (`ValueError` vs `RuntimeError`) and the full `errorMessage`.

---

**Query 3: Error rate — count by error type**
```
filter event = "order_failed"
| stats count() as failureCount by errorType
| sort failureCount desc
```
This aggregates failures by error type — exactly what an on-call engineer needs during an incident.

**Expected output:**
```
errorType               failureCount
ValueError              4
RuntimeError            2
```

---

**Query 4: Performance analysis — processing latency distribution**
```
fields processingMs
| filter event = "order_processed" or event = "order_failed"
| filter ispresent(processingMs)
| stats
    min(processingMs) as minMs,
    avg(processingMs) as avgMs,
    pct(processingMs, 50) as p50Ms,
    pct(processingMs, 90) as p90Ms,
    pct(processingMs, 99) as p99Ms,
    max(processingMs) as maxMs
    by bin(5m)
```
This shows latency percentiles over 5-minute windows — critical for identifying degradation.

> **Why This Matters:** Average latency is misleading. If 99 orders take 100ms and 1 order takes 10,000ms, the average is 199ms — but 1% of your customers are waiting 10 seconds. P99 latency is the metric that captures this tail behavior. A 10ms increase in P99 often signals a growing problem before it affects averages.

---

**Query 5: Business metrics — revenue by order type**
```
fields amount, orderType
| filter event = "order_processed"
| stats
    count() as orderCount,
    sum(amount) as totalRevenue,
    avg(amount) as avgOrderValue
    by orderType
```
This gives a real-time revenue breakdown by order type — a business KPI query, not just a debugging query.

**Expected output:**
```
orderType    orderCount    totalRevenue    avgOrderValue
EXPRESS      3             747.00          249.00
STANDARD     7             9314.92         1330.70  (includes the high-value orders)
```

---

**Query 6: Customer activity — top customers by order count**
```
fields customerId, orderId, amount
| filter event = "order_received"
| stats
    count() as orderCount,
    sum(amount) as totalSpend
    by customerId
| sort totalSpend desc
| limit 10
```
This identifies your highest-spending customers in real time — a query an analyst would run.

---

> **What Is Happening Behind the Scenes?** Logs Insights doesn't pre-index your logs. When you run a query, it scans the raw log data in the selected time range on the fly. This is why query time increases with larger time ranges. For production workloads with high log volumes, consider exporting frequently-queried logs to S3 and using Amazon Athena for historical analysis (much cheaper at scale).

### Step 7 — Save a query

1. After running Query 3 (Error rate by type), click **Save**.
2. **Query name:** `acme-error-rate-by-type`.
3. Click **Save query**.

**Validation:** Click **Queries** (left menu) → **Saved queries** → your query appears. During an incident, team members can quickly find and run pre-built queries without writing from scratch.

---

## Part 4: CloudWatch Metrics and Custom Metrics

### Step 8 — Explore Lambda built-in metrics

1. CloudWatch → **Metrics** → **All metrics** → **Browse** tab.
2. Click **Lambda** → **By Function Name**.
3. In the search box, type `acme-order-processor`.
4. Select these metrics:
   - **Invocations** (total calls)
   - **Errors** (failed invocations)
   - **Duration** (P50, P95)
   - **ConcurrentExecutions**
5. In the **Graphed metrics** tab, set Statistic to **Sum** for Invocations and Errors.
6. Set time range to **Last 1 hour**, period to **1 minute**.

**Validation:** Invocations shows ~16 (your test runs). Errors shows 6.

> **Namespace and Dimensions:**
> - **Namespace** = the grouping of related metrics. Lambda publishes to `AWS/Lambda`. Your custom metrics go to `Acme/OrderProcessing`. Each AWS service has its own namespace.
> - **Dimension** = a name/value pair that scopes a metric. `FunctionName = acme-order-processor` lets you see Errors *for this function* vs. all Lambda errors account-wide. Without dimensions, all Lambda invocations across all functions would be aggregated together — useless for debugging.

### Step 9 — Explore custom metrics

1. Still in **Metrics** → **All metrics** → **Browse**.
2. Look for the **Acme/OrderProcessing** custom namespace (scroll down past the AWS namespaces).
3. Click it and explore:
   - **OrdersProcessed** — count of successful invocations
   - **OrdersFailed** — count of failures
   - **OrderValue** — the dollar value emitted per order
   - **ProcessingLatencyMs** — processing time emitted per invocation
   - **ExpressOrdersProcessed** — counted separately by order type
   - **OrderFailureByType** — dimension `ErrorType` breaks failures by exception class

4. Add **OrdersProcessed** and **OrdersFailed** to the graph together. Set statistic to **Sum**, period **1 minute**.

> **Standard vs. High-Resolution Metrics:** By default, custom metrics have **standard resolution** (1-minute granularity). You can emit **high-resolution metrics** (1-second granularity) by adding `StorageResolution: 1` to the `put_metric_data` call. High-resolution metrics cost more but let you alarm on sub-minute anomalies — useful for detecting a DDoS spike in seconds, not minutes.

---

## Part 5: Metric Filters

### Step 10 — Create a Metric Filter for ERROR log lines

The built-in `Errors` metric only counts Lambda invocations that raise an uncaught exception. But what if your code catches an exception, logs it, and returns a 200? The invocation succeeds but an error occurred. A **metric filter** captures this.

1. CloudWatch → **Logs** → **Log groups** → click `/aws/lambda/acme-order-processor`.
2. **Metric filters** tab → **Create metric filter**.
3. **Filter pattern:**
```
{ $.event = "order_failed" }
```
This uses a JSON filter pattern matching log lines where the structured JSON has `"event": "order_failed"`.

4. Click **Test pattern** — it should highlight your failure log lines. Then click **Next**.
5. **Filter name:** `acme-order-failed-events`.
6. **Metric details:**
   - **Metric namespace:** `Acme/OrderProcessing`
   - **Metric name:** `LogOrderFailureCount`
   - **Metric value:** `1`
   - **Default value:** `0`
   - **Unit:** Count
7. Click **Next** → **Create metric filter**.

> **Why a Metric Filter AND a Lambda Errors Metric?** They measure different things:
> - Lambda `Errors` metric: counts invocations where the function raised an **uncaught exception** (Lambda marks it failed)
> - `LogOrderFailureCount` metric filter: counts log lines where your code **logged** a failure — even if it then returned normally
> In our function, we re-raise after logging, so they should match. In a function that swallows exceptions (bad practice, but common), the metric filter is the only way to count logged errors.

### Step 11 — Generate new logs to trigger the metric filter

Metric filters only apply to **logs ingested after the filter was created**.

1. Go to Lambda → `acme-order-processor` → run the `fail-payment` test event **2 more times**.
2. Wait 2–3 minutes.
3. CloudWatch → **Metrics** → **Acme/OrderProcessing** → find `LogOrderFailureCount`.

**Validation:** `LogOrderFailureCount` shows **Sum = 2** for the most recent minute. If still at 0, wait another minute and refresh.

---

## Part 6: CloudWatch Alarms

### Step 12 — Create a simple alarm on Lambda Errors

1. CloudWatch → **Alarms** → **All alarms** → **Create alarm**.
2. **Select metric** → Lambda → By Function Name → `acme-order-processor` → **Errors** → **Select metric**.
3. **Specify metric and conditions:**
   - **Statistic:** Sum
   - **Period:** 1 minute
   - **Threshold type:** Static
   - **Condition:** Greater/Equal `>=` `1`
   - **Datapoints to alarm:** 1 out of 1
4. Click **Next**.

### Step 13 — Create an SNS topic and subscribe

Before setting the notification, create the SNS topic:

1. Open a new browser tab → **SNS** → **Topics** → **Create topic**.
2. **Type:** Standard
3. **Name:** `acme-order-alerts`
4. Click **Create topic**.
5. On the topic page → **Create subscription**:
   - **Protocol:** Email
   - **Endpoint:** your email address
6. Click **Create subscription**.
7. **Check your email and click the confirmation link** — the subscription is not active until confirmed.

Return to the CloudWatch alarm creation tab:

5. **Notification:**
   - Alarm state trigger: **In alarm**
   - Choose **Select an existing SNS topic** → select `acme-order-alerts`
6. Click **Next**.
7. **Alarm name:** `acme-order-processor-errors`
8. **Description:** `Alert when Lambda errors >= 1 in any 1-minute window`
9. Click **Next** → **Create alarm**.

### Step 14 — Understand alarm states

> **Alarm States:**
> - **OK** — the metric is within threshold (function not erroring). Normal state.
> - **ALARM** — the metric has breached the threshold (errors detected). Action triggered.
> - **INSUFFICIENT_DATA** — not enough data to evaluate (common right after creation, or if the function hasn't run in the evaluated window). Neither OK nor ALARM.

### Step 15 — Trigger the alarm

1. Lambda → `acme-order-processor` → run `fail-payment` test **twice**.
2. CloudWatch → **Alarms** → watch `acme-order-processor-errors`.

**Validation:** Within 1–3 minutes, the alarm transitions to **ALARM** (red). If you confirmed your SNS subscription, you receive an email notification with the alarm details including the metric value and threshold.

Once no new errors occur, the alarm returns to **OK** after the evaluation period.

### Step 16 — Create a second alarm on OrderValue (custom metric)

This alarm detects if average order value drops suddenly — a business signal that large orders are failing:

1. **Create alarm** → **Select metric** → **Acme/OrderProcessing** → find `OrderValue` → **Select metric**.
2. **Statistic:** Average, **Period:** 5 minutes.
3. **Condition:** Less than `<` `50` (alert if average order value drops below $50).
4. **Notification:** select `acme-order-alerts`.
5. **Alarm name:** `acme-order-value-low`.
6. Create the alarm.

> **Why This Matters:** This is a **business KPI alarm**, not an infrastructure alarm. If average order value suddenly drops from $150 to $20, it might mean the high-value items' product pages are broken, or the payment processor is rejecting charges above a certain amount. This pattern — alarming on business metrics, not just infra metrics — is what separates mature engineering teams from reactive ones.

---

## Part 7: Composite Alarms

### Step 17 — Create a Composite Alarm

A **composite alarm** triggers only when multiple conditions are simultaneously true. Composite alarms dramatically reduce **alarm fatigue** — you don't want to wake someone at 2 AM because one error occurred. You want to wake them only when errors are high AND latency is high (which together indicate a real incident, not a transient blip).

First, create a latency alarm:

1. **Create alarm** → **Select metric** → Lambda → By Function Name → `acme-order-processor` → **Duration** → **Select metric**.
2. **Statistic:** p90 (90th percentile), **Period:** 1 minute.
3. **Condition:** Greater than `>` `2000` (alert if P90 duration exceeds 2000ms / 2 seconds).
4. No notification action (this alarm feeds into the composite, not directly to SNS).
5. **Alarm name:** `acme-order-processor-latency-high`.
6. Create.

Now create the composite alarm:

1. CloudWatch → **Alarms** → **Create alarm**.
2. Click **Composite alarm** (select radio button).
3. In the **Alarm rule** editor, type:
```
ALARM("acme-order-processor-errors") AND ALARM("acme-order-processor-latency-high")
```
4. **Notification:**
   - Trigger: **In alarm**
   - SNS topic: `acme-order-alerts`
5. **Alarm name:** `acme-order-processor-critical-incident`.
6. **Description:** `High severity: both error rate AND latency are elevated simultaneously. This indicates a real incident, not a transient blip.`
7. Create.

> **Why Composite Alarms:** Receiving a single isolated error alarm at 3 AM usually means a transient blip — one bad request, normal. But if BOTH errors AND latency spike simultaneously, that means the service is genuinely struggling. Composite alarms filter noise and surface only the signals that genuinely need human attention. The `AND` and `OR` operators in alarm rules let you express complex conditions without custom Lambda logic.

---

## Part 8: CloudWatch Dashboard

### Step 18 — Create a multi-widget dashboard

1. CloudWatch → **Dashboards** → **Create dashboard**.
2. **Dashboard name:** `acme-order-processor-ops`.
3. Click **Create dashboard**.
4. A dialog asks what widget to add first. Click **Cancel** — we'll add widgets manually.
5. Click **Add widget** to add each widget below.

**Widget 1: Invocations and Errors (line chart)**
- **Widget type:** Line
- **Metrics:** Lambda / acme-order-processor / Invocations (Sum) and Errors (Sum)
- **Period:** 1 minute
- **Title:** `Invocations vs Errors`
- Click **Create widget**

**Widget 2: Custom Metrics — OrdersProcessed vs OrdersFailed (stacked area)**
- **Add widget** → Stacked area
- Metrics: Acme/OrderProcessing / OrdersProcessed (Sum) and OrdersFailed (Sum)
- Period: 1 minute
- **Title:** `Business: Orders Processed vs Failed`

**Widget 3: OrderValue (average line)**
- **Add widget** → Line
- Metrics: Acme/OrderProcessing / OrderValue (Average)
- Period: 5 minutes
- **Title:** `Average Order Value ($)`

**Widget 4: Processing Latency P90 (line chart)**
- **Add widget** → Line
- Metrics: Lambda / acme-order-processor / Duration (p90)
- Period: 1 minute
- **Title:** `P90 Processing Latency (ms)`

**Widget 5: Alarm Status Panel**
- **Add widget** → Alarm Status
- Select alarms: `acme-order-processor-errors`, `acme-order-processor-latency-high`, `acme-order-processor-critical-incident`
- **Title:** `Alarm Status`

5. Arrange the widgets by dragging. Click **Save dashboard**.

**Validation:** The dashboard shows 5 widgets with real data from your test invocations. You can share this URL with anyone on the team.

> **Why Dashboards Matter:** A CloudWatch Dashboard is the **NOC (Network Operations Center) screen** for your service. During an incident, the first thing an on-call engineer opens should be the dashboard — not individual metric pages. A well-designed dashboard shows in one glance whether errors are spiking, latency is rising, and order volume is healthy or falling.

---

## Part 9: Anomaly Detection

### Step 19 — Enable Anomaly Detection on OrdersProcessed

CloudWatch Anomaly Detection uses ML to model a metric's normal behavior (seasonality, trends) and alerts when the metric deviates significantly — without requiring you to set a fixed threshold.

1. CloudWatch → **Metrics** → find `Acme/OrderProcessing` → `OrdersProcessed`.
2. Add it to the graph.
3. In the **Graphed metrics** tab, click the actions icon (three dots) for `OrdersProcessed` → **Add anomaly detection**.
4. A band appears on the graph representing the "expected" range based on historical patterns.
5. To alarm on anomalies:
   - CloudWatch → **Alarms** → **Create alarm** → **Select metric** → navigate to `OrdersProcessed` → under **Anomaly detection**, select the anomaly band metric → **Select metric**.
   - **Condition:** Outside the band (anomaly detected)
   - **Alarm name:** `acme-order-volume-anomaly`
   - No notification needed for this lab (observational only)

> **Why This Matters:** If Acme's order volume typically doubles every Friday evening, a fixed threshold of "alert if < 50 orders/minute" would fire every Monday morning when traffic naturally drops. Anomaly Detection learns this pattern and alerts only on **unexpected** deviations — true anomalies, not predictable variance.

> **Common Beginner Mistake:** Using Anomaly Detection for a brand-new metric with no history. Anomaly Detection needs 2–3 weeks of data to model seasonality accurately. For new services, start with static thresholds and switch to anomaly detection once sufficient history exists.

---

## Part 10: Advanced Observability — Reference Material

### CloudWatch Contributor Insights

**Contributor Insights** analyzes log data to find which contributors are causing the most impact on system behavior. For Acme:

- Which customers are generating the most errors?
- Which SKUs appear in the most failed orders?
- Which IP addresses are making the most API calls?

Enable Contributor Insights:
1. CloudWatch → **Contributor Insights** → **Create rule**.
2. Select the log group `/aws/lambda/acme-order-processor`.
3. Create a rule using the JSON structure of your logs (e.g., group by `$.customerId` and count `$.event = "order_failed"`).

The resulting visualization shows a **top-N list** updated in real time — e.g., "Customer C-2001 generated 42% of all errors in the last hour."

### CloudWatch ServiceLens

**ServiceLens** is a unified view that combines CloudWatch Metrics, CloudWatch Logs, and **X-Ray traces** into a single map. It shows:
- Which services are calling which
- The error rate and latency for each service-to-service connection
- Distributed traces you can click into for root cause analysis

Enable ServiceLens:
1. Enable X-Ray Active Tracing on your Lambda (Lambda → Configuration → Monitoring → Enable X-Ray).
2. CloudWatch → **ServiceLens** → **Service Map** — your Lambda and all services it calls appear as nodes.

> **Why X-Ray + ServiceLens?** CloudWatch Logs shows you what happened inside one Lambda. X-Ray shows you what happened across the entire call chain: API Gateway → Lambda → DynamoDB → external payment API. If a payment timeout is causing Lambda errors, X-Ray shows the exact segment that timed out and for how long.

### CloudWatch Logs Subscriptions

**Log Subscriptions** deliver log events in real-time to another destination as they are written. Use cases:
- **Lambda subscription:** trigger a real-time alerting Lambda that formats and sends Slack notifications for ERROR lines
- **Kinesis Data Streams:** stream logs to a SIEM (Security Information and Event Management) system
- **Amazon OpenSearch Service:** real-time log indexing for Kibana dashboards

Create a subscription filter:
1. Log group → **Subscription filters** tab → **Create Lambda subscription filter**.
2. Select a Lambda function to receive the log stream in real-time.
3. **Filter pattern:** `ERROR` (or a JSON pattern like `{ $.event = "order_failed" }`).

The Lambda receives compressed, base64-encoded log event batches whenever new matching log lines are written. This enables sub-second alerting — much faster than alarm evaluation periods.

---

## Challenges

> Attempt these challenges on your own before looking at the solutions in `09-solutions.md`.

### Challenge 1: Composite Alarm — High Error Rate AND Low Order Volume

The `acme-order-processor-critical-incident` alarm you created uses errors AND latency. But a different failure mode exists: the function processes orders with near-zero errors but the order volume suddenly drops to nothing — meaning orders are being silently dropped before reaching Lambda (e.g., the API Gateway has failed).

**Your task:**

1. Create an alarm on `OrdersProcessed` (custom metric) that triggers when Sum < 1 over 5 minutes. Name it `acme-order-volume-too-low`.
2. Create a second composite alarm that triggers when BOTH `acme-order-processor-errors` is in ALARM AND `acme-order-volume-too-low` is in ALARM.
   - Name it: `acme-order-critical-errors-with-low-volume`
   - Wire it to `acme-order-alerts` SNS topic
3. Explain in a comment (in your notes) why this alarm combination is meaningful: what specific failure scenario does it detect that neither individual alarm would catch alone?
4. Test by NOT running any Lambda invocations for 5+ minutes, then running several failure invocations, and verify the composite alarm fires.

**Hints:**
- Composite alarm rule syntax: `ALARM("alarm-name-1") AND ALARM("alarm-name-2")`
- For the volume alarm: be careful about `INSUFFICIENT_DATA` behavior — when no metric data is published (function not called), the alarm may go to INSUFFICIENT_DATA rather than ALARM. Research the "Treat missing data as" setting for the volume alarm.
- Think about the difference between "errors are high" and "volume is zero" — one means orders are failing, the other means no orders are arriving at all.

---

### Challenge 2: Logs Insights Dashboard Widget

The on-call team needs a dashboard that shows order processing trends in a visual format without requiring them to run manual Logs Insights queries during an incident.

**Your task:**

1. Write a Logs Insights query that shows order volume (count of `order_processed` events) grouped by 5-minute windows AND by `orderType`. The result should show a time series per order type.
2. Add this query as a **Logs Insights visualization widget** to the `acme-order-processor-ops` dashboard.
3. Write a second query that shows the top 5 error messages ordered by frequency over the last hour.
4. Add this as a **table widget** to the same dashboard.
5. Generate fresh test data (run success and failure events 5+ times each) and verify the widgets update.

**Hints:**
- Logs Insights queries can be added directly as dashboard widgets: **Add widget** → **Logs table** or **Logs visualization**
- For grouping by time AND a field: `stats count() by bin(5m), orderType`
- The `sort` command in Logs Insights sorts ascending by default; use `desc` for "top by frequency"
- Dashboard Logs Insights widgets re-run the query each time the dashboard loads — no caching of results

---

## Key Takeaways

1. **The Observability Trinity:** Logs (what happened), Metrics (how much/how fast), Traces (where across services). Use all three together.
2. **Structured JSON logs** (emit JSON from your code) make Logs Insights queries dramatically more powerful than parsing free-text strings.
3. **Custom metrics** (`put_metric_data`) capture business KPIs — orders processed, revenue, error rate by type — that built-in AWS metrics cannot provide.
4. **Logs Insights** is a scalable query engine for logs — use it instead of scrolling streams; save frequently-used queries.
5. **P99 latency** is more operationally useful than average — it captures tail behavior that affects real customers.
6. **Metric Filters** enable alarming on log content, not just invocation failures — catches exceptions that are swallowed by application code.
7. **Composite alarms** reduce noise by requiring multiple conditions simultaneously — fewer false alerts, better sleep for on-call engineers.
8. **Dashboards** are the incident response starting point — build them before incidents, not during.
9. **Anomaly Detection** learns seasonality and trends — better than fixed thresholds for metrics with predictable variance.
10. **Log Subscriptions** enable sub-second real-time log streaming to Lambda, Kinesis, or OpenSearch.

---

## Cleanup Instructions

Delete in this order:

1. **Dashboard:**
   - CloudWatch → Dashboards → select `acme-order-processor-ops` → Delete

2. **Alarms** (delete all `acme-*` alarms):
   - CloudWatch → Alarms → select each → Actions → Delete
   - Delete: `acme-order-processor-errors`, `acme-order-processor-latency-high`, `acme-order-processor-critical-incident`, `acme-order-value-low`, `acme-order-volume-anomaly`, and any challenge alarms

3. **Metric Filters:**
   - CloudWatch → Logs → Log groups → `/aws/lambda/acme-order-processor` → Metric filters tab → select `acme-order-failed-events` → Delete

4. **Contributor Insights rules (if created):**
   - CloudWatch → Contributor Insights → select rule → Delete

5. **SNS:**
   - SNS → Subscriptions → delete `acme-order-alerts` subscription
   - SNS → Topics → select `acme-order-alerts` → Delete

6. **Lambda:**
   - Lambda → select `acme-order-processor` → Actions → Delete

7. **Lambda execution role:**
   - IAM → Roles → search `acme-order-processor` → Delete the role

8. **Log groups:**
   - CloudWatch → Logs → Log groups → select `/aws/lambda/acme-order-processor` → Actions → Delete log group(s)

9. **Custom metrics:** Cannot be manually deleted — automatically expire after 15 months of inactivity.

**Validation:** CloudWatch Alarms list shows no `acme-*` alarms. Lambda console shows no `acme-order-processor` function. CloudWatch Dashboards shows no `acme-order-processor-ops` dashboard.
