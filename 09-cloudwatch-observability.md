# Exercise 09 — Observability with Amazon CloudWatch: Logs, Metrics, and Alarms

## Estimated Duration

~40 minutes

## Scenario / Business Context

**Acme Retail** just shipped a new order-processing Lambda function to production. It "works on my machine," but leadership keeps asking the operations team an uncomfortable question: *"How do we know it's healthy right now?"* Today the answer is "we don't — we wait for customers to complain."

Your job is to give Acme **eyes** on that function. You'll use **Amazon CloudWatch** to (1) read the function's **logs**, (2) watch its **metrics** (invocations and errors), and (3) create an **alarm** that fires the moment the function starts erroring — so the team hears about problems before customers do.

## Learning Objectives

By the end of this exercise you will be able to:

- Navigate **CloudWatch Log groups** and **log streams** and find specific log lines.
- Query logs with **CloudWatch Logs Insights**.
- Clearly distinguish **CloudWatch Logs** (text events) from **CloudWatch Metrics** (numeric time series), and both from **AWS CloudTrail**.
- Read Lambda **metrics** (Invocations, Errors) and explain **namespaces** and **dimensions**.
- Create a **CloudWatch Alarm** on an error metric and understand alarm states.
- Set **log retention** to control storage cost.

## AWS Services Used

- **Amazon CloudWatch** (Logs, Logs Insights, Metrics, Alarms)
- **AWS Lambda** (the function we're monitoring)
- **Amazon SNS** (optional — for alarm notifications)
- **AWS IAM** (the Lambda execution role that grants logging permissions)

## Prerequisites

- An AWS account.
- An **IAM user** (or IAM Identity Center user) with permissions for CloudWatch, Lambda, IAM, and SNS. **Do not use the root user.**
- Working in region **US East (N. Virginia) `us-east-1`**. Confirm the region selector (top-right) reads **N. Virginia**.
- **A Lambda function to monitor.** This lab is self-contained: Step 1 walks you through creating a minimal **Python 3.12** function called `acme-monitored-fn`. If you built a function in **Lab 03**, you could adapt it, but the code here is written to generate both logs *and* errors on demand, so creating the new one is recommended.

> **AWS Mental Model:** Think of **CloudWatch as the "black box flight recorder" plus the cockpit dashboard for your AWS workloads.** Logs are the detailed transcript of what happened; Metrics are the gauges (speed, altitude, error rate); Alarms are the warning lights that turn red when a gauge crosses a limit.

---

## Step 1 — Create the Lambda function to monitor

1. Console search bar → **Lambda** → open it. Confirm region is **N. Virginia `us-east-1`**.
2. Click **Create function** → **Author from scratch**.
3. **Function name:** `acme-monitored-fn`
4. **Runtime:** **Python 3.12**.
5. Leave **Create a new role with basic Lambda permissions** selected.
   - **What this does:** AWS creates an execution role granting `logs:CreateLogGroup`, `logs:CreateLogStream`, and `logs:PutLogEvents`. Without these, the function couldn't write to CloudWatch and you'd have nothing to observe.
6. Click **Create function**.
7. In the **Code source** editor, replace `lambda_function.py` with:

```python
import json
import logging

# Configure a logger. Lambda automatically sends both print() output
# and logger output to CloudWatch Logs.
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    order_id = event.get("orderId", "unknown")
    logger.info(f"Received order {order_id}")
    print(f"INFO processing order {order_id}")

    # Fail on demand so we can generate an Errors metric and an alarm.
    if event.get("fail") is True:
        logger.error(f"ERROR failed to process order {order_id}")
        raise Exception(f"Simulated failure processing order {order_id}")

    logger.info(f"Order {order_id} processed successfully")
    return {"orderId": order_id, "status": "OK"}
```

8. Click **Deploy** and wait for **"Changes deployed."**

> **Security Consideration:** A Lambda function can only write logs if its **execution role** includes the CloudWatch Logs permissions (`logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`). The "basic Lambda permissions" role adds these for you. If a function's logs never appear, the *first* thing to check is whether its execution role has these permissions.

### 1a. Generate some activity (logs + metrics)

1. In the function page, open the **Test** tab.
2. Create a test event named `ok` with body:

```json
{ "orderId": "5001" }
```

3. Click **Test**. Repeat **3–4 times** (each click is one invocation). You should see **succeeded** each time.
4. Now create a second test event named `boom` with body:

```json
{ "orderId": "5002", "fail": true }
```

5. Click **Test** with the `boom` event **2 times**. Each run should report an **error** (the function raised an exception). That's intentional — it produces the **Errors** metric and `ERROR` log lines we need later.

> **Why This Matters:** Metrics and logs don't appear until the function actually *runs*. By invoking it a handful of times — some succeeding, some failing — you've generated real telemetry to explore, exactly like a production function under load.

---

## Step 2 — Explore CloudWatch Logs

1. Console search bar → **CloudWatch** → open it. Confirm region **N. Virginia**.
2. Left menu → **Logs** → **Log groups**.
3. Find and click **`/aws/lambda/acme-monitored-fn`**.

> **AWS Mental Model — log group vs log stream:**
> - A **log group** is the *container* for all logs from one source (here, all logs from `acme-monitored-fn`). Think of it as a folder.
> - A **log stream** is a *sequence of log events from one source instance* (one Lambda execution environment). Think of it as a single file inside that folder. A busy function has many streams.

4. Inside the log group you'll see one or more **log streams** (names like `2026/07/12/[$LATEST]abc123...`). Click the most recent one.
5. You should see your log lines: `Received order 5001`, `INFO processing order 5001`, `Order 5001 processed successfully`, and for the failing runs, `ERROR failed to process order 5002` plus the Python traceback.

**Validation:** You can see both your `INFO` lines and your `ERROR` lines in the stream.

### 2a. Query with CloudWatch Logs Insights

Scrolling streams by hand doesn't scale. **Logs Insights** lets you *query* across streams.

1. CloudWatch left menu → **Logs** → **Logs Insights**.
2. In the **Select log group(s)** dropdown, choose **`/aws/lambda/acme-monitored-fn`**.
3. Replace the default query with exactly this:

```
fields @timestamp, @message
| sort @timestamp desc
| limit 20
```

4. Set the time range (top-right) to **Last 30 minutes**.
5. Click **Run query**.

**Validation:** A results table shows your most recent 20 log events, newest first — including both your processing lines and the `ERROR` lines. Each row has a `@timestamp` and the `@message` text.

> **What Is Happening Behind the Scenes?** `@timestamp` and `@message` are **system fields** CloudWatch attaches to every log event. Logs Insights parses your log text on the fly so you can `filter`, `sort`, and aggregate it — no database setup required.

> **Common Beginner Mistake:** Confusing **CloudWatch Logs with AWS CloudTrail**. They are different services. **CloudWatch Logs** stores the *application output* your code emits (print/logger lines). **AWS CloudTrail** records *API activity in your account* — "who called which AWS API, when" (e.g., "user X created a Lambda function"). If you want to see your function's `print()` output, that's **CloudWatch Logs**, not CloudTrail.

---

## Step 3 — Explore CloudWatch Metrics

1. CloudWatch left menu → **Metrics** → **All metrics**.
2. Under the **Browse** tab, click the **Lambda** namespace.
3. Click **By Function Name**.
4. In the list, check the boxes for **`acme-monitored-fn`** under the **Invocations** metric and again under the **Errors** metric. (You can filter the search box by typing `acme-monitored-fn`.)
5. The graph updates. Set the time range (top-right) to **1h** and set the **Period** (via the graph's options) to something small like **1 minute** so your recent activity is visible.
6. Switch the graph statistic to **Sum** (Graphed metrics tab → Statistic column) so counts add up correctly.

**Validation:**

- **Invocations** shows a bar/line equal to the total number of times you clicked Test (e.g., ~5–6).
- **Errors** shows a value of **2** (the two `boom` invocations).

> **AWS Mental Model — namespaces and dimensions:**
> - A **namespace** is a grouping of related metrics. AWS Lambda publishes into the **`AWS/Lambda`** namespace; other services have their own (`AWS/S3`, `AWS/DynamoDB`, etc.).
> - A **dimension** is a name/value pair that scopes a metric to a specific thing. Here the dimension is **`FunctionName = acme-monitored-fn`**. Dimensions let you ask "Errors *for this function*" rather than "Errors across all functions."

> **Common Beginner Mistake:** Confusing **CloudWatch Metrics with CloudWatch Logs**. They are distinct:
> - **Logs = text events** (the words your code printed). Good for *reading what happened*.
> - **Metrics = numeric time series** (counts, durations, percentages over time). Good for *graphing trends and alarming*.
> You cannot draw a trend line directly on raw log text, and you cannot read a stack trace inside a metric. You often use both together: a metric alarm tells you *that* errors spiked; the logs tell you *why*.

---

## Step 4 — Create an Alarm on the Errors metric

An alarm watches a metric and changes state when the metric crosses a threshold.

1. CloudWatch left menu → **Alarms** → **All alarms** → **Create alarm**.
2. Click **Select metric**.
3. Choose **Lambda** → **By Function Name** → find **`acme-monitored-fn`** with metric name **Errors** → check it → **Select metric**.
4. In **Specify metric and conditions**:
   - **Statistic:** **Sum**.
   - **Period:** **1 minute**.
   - **Threshold type:** **Static**.
   - **Whenever Errors is...:** **Greater/Equal `>=`** than **`1`**.
   - Under **Additional configuration**, set **Datapoints to alarm** to **1 out of 1** (fire as soon as one period has ≥ 1 error).
5. Click **Next**.
6. **Notification:**
   - **Option A (with email):** under **Alarm state trigger** = **In alarm**, choose **Create new topic**, give it a name like `acme-alarm-topic`, enter your email, click **Create topic**. **Then check your email and click the SNS subscription confirmation link** — unconfirmed subscriptions receive nothing.
   - **Option B (skip notification):** click **Remove** on the notification block so the alarm has no action. This is perfectly fine for the lab; you'll observe the state change in the console instead.
7. Click **Next**.
8. **Alarm name:** `acme-monitored-fn-errors`. Add an optional description. Click **Next** → review → **Create alarm**.

> **AWS Mental Model — alarm states:**
> - **OK** — the metric is within the threshold (healthy).
> - **ALARM** — the metric has breached the threshold (something's wrong).
> - **INSUFFICIENT_DATA** — not enough data yet to decide (common right after creation, or when the function hasn't run in the evaluated window).

### 4a. Trigger the alarm

1. Go back to **Lambda** → `acme-monitored-fn` → **Test** → run the **`boom`** event (the one with `"fail": true`) **once or twice** to produce a fresh error in the current minute.
2. Return to **CloudWatch** → **Alarms**. Watch `acme-monitored-fn-errors`.

**Validation:**

- Within roughly **1–3 minutes** the alarm transitions from **OK** (or **INSUFFICIENT_DATA**) to **ALARM**, because Errors for the latest 1-minute period is ≥ 1.
- If you set up Option A, you'll also receive an **email notification** when it enters ALARM.
- Once no new errors occur for the following minutes, the metric returns to 0 and the alarm goes back to **OK**. (This lag is expected — alarms evaluate on period boundaries.)

> **Assessment Connection:** Monitoring function health with an **Errors metric alarm** is a standard operational pattern. You may be asked which service holds *logs* vs *metrics*, what an alarm's three states mean, or how to be notified automatically when errors appear. You just wired all of that together.

---

## Step 5 — Set Log Retention (cost control)

By default, Lambda log groups keep logs **forever** ("Never expire"), and stored logs cost money over time.

1. **CloudWatch** → **Logs** → **Log groups** → click **`/aws/lambda/acme-monitored-fn`**.
2. Note the **Retention** column likely says **Never expire**.
3. Click **Actions** → **Edit retention setting(s)** (or the **Retention** field).
4. Set retention to **3 days**.
5. Click **Save**.

**Validation:** The log group's **Retention** now shows **3 days**. Logs older than that are deleted automatically going forward.

> **Cost Awareness:** CloudWatch charges for **log ingestion** (data written) and **log storage** (data retained over time), and **alarms** carry a small monthly cost each. Leaving retention at **Never expire** means storage cost grows forever. Setting a sensible retention (days/weeks) and deleting unused log groups and alarms keeps costs near zero. Metrics for AWS services and basic alarms are cheap, but "cheap × forever × many resources" adds up — clean up when done.

---

## Key Takeaways

- **CloudWatch is your observability hub**: Logs (text), Metrics (numbers), Alarms (thresholds/notifications).
- A **log group** is the container for a source's logs; a **log stream** is one sequence of events within it.
- **Logs Insights** lets you *query* logs (`fields ... | sort ... | limit ...`) instead of scrolling streams.
- **CloudWatch Logs ≠ AWS CloudTrail.** Logs = your application's output. CloudTrail = who called which AWS API.
- **Logs ≠ Metrics.** Logs are text events; metrics are numeric time series you can graph and alarm on.
- Metrics live in a **namespace** (`AWS/Lambda`) and are scoped by **dimensions** (`FunctionName`).
- An **alarm** has three states: **OK**, **ALARM**, **INSUFFICIENT_DATA**.
- Set **log retention** to avoid paying to store logs forever.

---

## Cleanup Instructions

Delete in this order.

1. **Alarm:**
   - **CloudWatch** → **Alarms** → select **`acme-monitored-fn-errors`** → **Actions** → **Delete** → confirm.
2. **SNS topic and subscription (only if you created them in Option A):**
   - **Amazon SNS** → **Subscriptions** → select the `acme-alarm-topic` subscription → **Delete**.
   - **Amazon SNS** → **Topics** → select **`acme-alarm-topic`** → **Delete** → confirm.
3. **Lambda function:**
   - **Lambda** → select **`acme-monitored-fn`** → **Actions** → **Delete** → confirm.
4. **Lambda execution role (auto-created):**
   - **IAM** → **Roles** → search **`acme-monitored-fn-role`** → select → **Delete** → confirm.
5. **Log group:**
   - **CloudWatch** → **Logs** → **Log groups** → select **`/aws/lambda/acme-monitored-fn`** → **Actions** → **Delete log group(s)** → confirm.

After cleanup, confirm there are no `acme-monitored-fn*` entries in Lambda, CloudWatch Alarms, or CloudWatch Log groups.

---

## Early-Finisher Challenge

The built-in Lambda **Errors** metric only counts *exceptions/failed invocations*. But suppose Acme's code logs the word **`ERROR`** for problems that *don't* crash the function (e.g., "ERROR: payment gateway slow, retrying"). Those won't show up in the Errors metric at all.

**Challenge:** Create a **metric filter** on the `/aws/lambda/acme-monitored-fn` log group that increments a **custom metric** every time a log line contains the word `ERROR`. Then create an **alarm** on that custom metric. This is how teams alarm on *log content*, not just built-in metrics.

---

## Challenge Solution

### Step 1 — Create the metric filter

1. **CloudWatch** → **Logs** → **Log groups** → click **`/aws/lambda/acme-monitored-fn`**.
2. Open the **Metric filters** tab → **Create metric filter**.
3. **Filter pattern:** enter exactly:

```
ERROR
```

   - **What this does:** This matches any log event whose text contains the token `ERROR`. (CloudWatch term-matching is case-sensitive, so it matches your `ERROR failed to process...` lines.)
4. Under **Test pattern**, pick your log group's data and click **Test pattern** — it should highlight the `ERROR` lines you generated earlier. Click **Next**.
5. **Filter name:** `acme-error-keyword`.
6. **Metric details:**
   - **Metric namespace:** `Acme/OrderProcessing` (a custom namespace — creating a new one is fine, just type it).
   - **Metric name:** `LogErrorCount`.
   - **Metric value:** `1` (emit 1 each time the pattern matches).
   - **Default value:** `0` (report 0 when there are no matches, so the metric graphs cleanly).
   - Leave **Unit** as **None**.
7. Click **Next** → review → **Create metric filter**.

> **What Is Happening Behind the Scenes?** A metric filter continuously scans *incoming* log events. Every event matching the pattern publishes a data point (value `1`) to your custom metric. Note: metric filters only act on logs ingested **after** the filter is created — you must generate fresh matching logs to see the metric move.

### Step 2 — Generate matching log lines

1. **Lambda** → `acme-monitored-fn` → **Test** → run the **`boom`** event (`{ "orderId": "5002", "fail": true }`) **2–3 times**. Each run logs an `ERROR ...` line, which the filter matches.

### Step 3 — Validate the custom metric increments

1. **CloudWatch** → **Metrics** → **All metrics** → **Browse**.
2. Find and click your custom namespace **`Acme/OrderProcessing`**.
3. Open **Metrics with no dimensions** (or the group shown) and select **`LogErrorCount`**.
4. Set time range to **Last 15 minutes**, statistic **Sum**, period **1 minute**.

**Validation:** `LogErrorCount` shows a **Sum** equal to the number of `ERROR` log lines you just produced (e.g., 2–3). If it's flat at 0, wait a minute for ingestion and re-run the `boom` test — remember the filter only counts logs written *after* it was created.

### Step 4 — Create an alarm on the custom metric

1. **CloudWatch** → **Alarms** → **Create alarm** → **Select metric**.
2. Navigate **Acme/OrderProcessing** → **Metrics with no dimensions** → check **`LogErrorCount`** → **Select metric**.
3. Conditions: **Statistic** = **Sum**, **Period** = **1 minute**, **Static**, **Greater/Equal `>=` 1**, **Datapoints to alarm** = **1 of 1**.
4. **Next** → for notification, either reuse/create an SNS topic or **Remove** the notification (console-only observation is fine).
5. **Alarm name:** `acme-log-error-keyword` → **Next** → **Create alarm**.
6. Run the **`boom`** test once more, then watch the alarm transition to **ALARM** within ~1–3 minutes.

**Validation:** `acme-log-error-keyword` enters **ALARM** shortly after a fresh `ERROR` log line — proving you can alarm on *log content*, independent of the built-in Errors metric.

### Step 5 — Cleanup for the challenge

In addition to the main **Cleanup Instructions**, remove the challenge-only resources:

1. **CloudWatch** → **Alarms** → delete **`acme-log-error-keyword`**.
2. **CloudWatch** → **Logs** → **Log groups** → `/aws/lambda/acme-monitored-fn` → **Metric filters** tab → select **`acme-error-keyword`** → **Delete**. (Deleting the log group in the main cleanup also removes its metric filters, so this step is optional if you're deleting the log group anyway.)
3. **Note:** Custom metrics like `LogErrorCount` cannot be manually deleted; they simply **expire automatically** after 15 months with no new data. No further action needed.

Then run the main **Cleanup Instructions** to remove the function, role, alarm, log group, and any SNS topic.
