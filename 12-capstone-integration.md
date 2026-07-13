# Lab 12: Capstone — End-to-End Order Intake (API → Lambda → DynamoDB + SNS)

## Estimated Duration

~60 minutes

## Scenario / Business Context

**Acme Retail** wants a tiny but complete **order intake** service: when a customer places an order, an HTTP request comes in the "front door," a piece of compute processes it, the order is **stored durably**, and the operations team gets a **notification**. This is the same shape as a real production order service — just scaled down so you can build the whole thing yourself.

In this capstone you wire several AWS services into one flow, reusing patterns from earlier labs:

```
Client (curl)
     |
     v  POST /order
+-----------------+       +---------------------+
|  API Gateway    |  -->  |   AWS Lambda        |
|  HTTP API (v2)  |       |  acme-capstone-order|
+-----------------+       +----------+----------+
                                     |
                     +---------------+----------------+
                     v                                v
            +-----------------+              +------------------+
            |  DynamoDB       |              |  SNS topic       |
            |  AcmeCapstone   |              |  acme-capstone-  |
            |  Orders         |              |  notify (email)  |
            +-----------------+              +------------------+
```

## Learning Objectives

By the end of this exercise you will be able to:

- Compose an event-driven flow: **HTTP API → Lambda → DynamoDB + SNS**.
- Read an **HTTP API payload format 2.0** event in Lambda.
- Grant a Lambda execution role **least-privilege** permissions scoped to specific ARNs.
- Use **environment variables** to pass configuration (table name, topic ARN) into code.
- Validate an end-to-end system with `curl`, the DynamoDB console, and email.

## AWS Services Used

- Amazon API Gateway (HTTP API, payload format 2.0)
- AWS Lambda (Python 3.12)
- Amazon DynamoDB
- Amazon SNS
- AWS IAM (Lambda execution role + inline policy)
- Amazon CloudWatch (logs; alarm in the challenge)

## Prerequisites

- An AWS account.
- Sign in as an **IAM user** (or IAM Identity Center user) with permissions for Lambda, API Gateway, DynamoDB, SNS, IAM, and CloudWatch. **Do not use the root user.**
- Region: **us-east-1** (N. Virginia).
- **Lab-specific:** a terminal with `curl` (built into macOS/Linux; on Windows use PowerShell's `curl.exe` or Git Bash). An email address you can check to confirm the SNS subscription.

---

## Part 1 — Create the DynamoDB Table

1. Open **DynamoDB** (region us-east-1) > **Tables** > **Create table**.
2. Table name: `AcmeCapstoneOrders`.
3. **Partition key:** `orderId`, type **String**.
   - **Why it matters:** the partition key uniquely identifies each order and determines how DynamoDB distributes/stores items. Each `put_item` with a given `orderId` writes (or overwrites) that order.
4. **Table settings:** leave **Default settings** (On-demand capacity — no capacity planning, pay per request, effectively free at lab volume).
5. Choose **Create table**. Wait until status = **Active**.

---

## Part 2 — Create the SNS Topic + Email Subscription

1. Open **SNS** (region us-east-1) > **Topics** > **Create topic**.
2. Type: **Standard**. Name: `acme-capstone-notify`. Choose **Create topic**.
3. **Copy the topic ARN** — it looks like `arn:aws:sns:us-east-1:111122223333:acme-capstone-notify`. You'll need it for the Lambda env var and the IAM policy.
4. **Create subscription:** on the topic page choose **Create subscription** > Protocol **Email** > Endpoint = your email > **Create subscription**.
5. **Confirm it:** open the confirmation email and click **Confirm subscription**. Status must become **Confirmed**.
   - **Common Beginner Mistake:** if you skip confirmation, the code still "succeeds" (SNS accepts the publish) but **no email is delivered**, and you'll wrongly think the Lambda is broken.

---

## Part 3 — Create the Lambda Function

1. Open **Lambda** (region us-east-1) > **Create function**.
2. Choose **Author from scratch**.
   - Function name: `acme-capstone-order`.
   - Runtime: **Python 3.12**.
   - Architecture: leave default (`x86_64`).
   - **Permissions:** expand and leave **Create a new role with basic Lambda permissions** (this auto-creates an execution role that can write CloudWatch logs). We'll add DynamoDB/SNS permissions next.
3. Choose **Create function**.
4. In the **Code source** editor, replace the contents of `lambda_function.py` with the following, then choose **Deploy**:

   ```python
   import json
   import os
   import boto3

   dynamodb = boto3.client("dynamodb")
   sns = boto3.client("sns")

   TABLE_NAME = os.environ["TABLE_NAME"]
   TOPIC_ARN = os.environ["TOPIC_ARN"]


   def lambda_handler(event, context):
       # HTTP API payload format 2.0 delivers the request body as a string
       # in event["body"]. It may be base64-encoded for binary payloads.
       raw_body = event.get("body") or "{}"
       if event.get("isBase64Encoded"):
           import base64
           raw_body = base64.b64decode(raw_body).decode("utf-8")

       try:
           data = json.loads(raw_body)
       except json.JSONDecodeError:
           return _response(400, {"message": "Invalid JSON body"})

       order_id = data.get("orderId")
       item = data.get("item")
       total = data.get("total")

       if not order_id or item is None or total is None:
           return _response(
               400,
               {"message": "orderId, item, and total are required"},
           )

       # Write the order to DynamoDB. All values are strings for the
       # low-level client; 'total' is stored as a Number (N) attribute.
       dynamodb.put_item(
           TableName=TABLE_NAME,
           Item={
               "orderId": {"S": str(order_id)},
               "item": {"S": str(item)},
               "total": {"N": str(total)},
           },
       )

       # Publish a confirmation notification.
       sns.publish(
           TopicArn=TOPIC_ARN,
           Subject="Acme order received",
           Message=(
               f"Order {order_id} received.\n"
               f"Item: {item}\n"
               f"Total: {total}"
           ),
       )

       return _response(
           200,
           {
               "message": "Order accepted",
               "orderId": str(order_id),
           },
       )


   def _response(status_code, body_dict):
       return {
           "statusCode": status_code,
           "headers": {"Content-Type": "application/json"},
           "body": json.dumps(body_dict),
       }
   ```

5. **Set environment variables.** Go to **Configuration** > **Environment variables** > **Edit** > **Add environment variable** (add both), then **Save**:
   - Key `TABLE_NAME`, Value `AcmeCapstoneOrders`
   - Key `TOPIC_ARN`, Value = the SNS topic ARN you copied in Part 2
   - **Why env vars:** the code stays generic; configuration (which table, which topic) lives outside the code and can change per environment without editing/redeploying source.

---

## Part 4 — Grant Least-Privilege Permissions to the Execution Role

The auto-created execution role can write logs but **cannot yet call DynamoDB or SNS**. Add exactly the two permissions it needs, scoped to your specific resources.

1. In the Lambda function, go to **Configuration** > **Permissions**. Under **Execution role**, click the **role name** link — this opens the IAM role in a new tab.
2. On the role page choose **Add permissions** > **Create inline policy**.
3. Choose the **JSON** tab and paste the following. **Replace** `ACCOUNT_ID` with your 12-digit AWS account ID (find it in the top-right account menu). The region is already set to `us-east-1` to match this lab:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AllowPutOrder",
         "Effect": "Allow",
         "Action": "dynamodb:PutItem",
         "Resource": "arn:aws:dynamodb:us-east-1:ACCOUNT_ID:table/AcmeCapstoneOrders"
       },
       {
         "Sid": "AllowPublishNotify",
         "Effect": "Allow",
         "Action": "sns:Publish",
         "Resource": "arn:aws:sns:us-east-1:ACCOUNT_ID:acme-capstone-notify"
       }
     ]
   }
   ```

4. Choose **Next**, name the policy `acme-capstone-access`, and choose **Create policy**.
   - **What each statement grants:** `dynamodb:PutItem` **only** on the `AcmeCapstoneOrders` table, and `sns:Publish` **only** on the `acme-capstone-notify` topic. Nothing else.

**Security Consideration:** This is **least privilege** in action — the role can write orders to *this one table* and publish to *this one topic*, nothing more. If this function were ever compromised, the blast radius is limited to two specific resources. Avoid the tempting shortcut of `dynamodb:*` on `Resource: "*"` — that would let the function read/delete every table in the account.

**Assessment Connection:** Scoping IAM policies to specific ARNs (not `*`) and passing config via environment variables are exactly the patterns evaluated in the later serverless capstone. Practicing them here builds the muscle memory.

---

## Part 5 — Create the HTTP API and Route

1. Open **API Gateway** (region us-east-1) > **APIs** > **Create API** > under **HTTP API** choose **Build**.
2. **Integrations:** choose **Add integration** > **Lambda** > Region **us-east-1** > Lambda function `acme-capstone-order`.
3. API name: `acme-capstone-api`. Choose **Next**.
4. **Configure routes:**
   - Method: **POST**
   - Resource path: `/order`
   - Integration target: `acme-capstone-order`
   - Choose **Next**.
   - **What "proxy" integration means:** the entire request (method, path, headers, body) is passed to Lambda as a **payload format 2.0** event, and whatever your function returns (`statusCode`, `headers`, `body`) becomes the HTTP response. HTTP APIs use payload format **2.0** by default.
5. **Stages:** leave the default `$default` stage with **Auto-deploy** enabled. Choose **Next** > **Create**.
6. Copy the **Invoke URL** (looks like `https://abcd1234.execute-api.us-east-1.amazonaws.com`). Your full endpoint is that URL + `/order`.

> **What Is Happening Behind the Scenes?** API Gateway wraps your POST into a JSON **event** (payload v2.0) with the raw body in `event["body"]`. It invokes Lambda using resource-based permission that the console added automatically. Your code parses the body, and because its **execution role** now allows `dynamodb:PutItem` and `sns:Publish`, boto3's cross-service calls are authorized. DynamoDB stores the item; SNS fans the message out to your confirmed email subscription.

---

## Part 6 — Test and Validate End-to-End

1. Run this from your terminal (replace the host with your Invoke URL):

   ```bash
   curl -X POST \
     "https://abcd1234.execute-api.us-east-1.amazonaws.com/order" \
     -H "Content-Type: application/json" \
     -d '{"orderId": "A-1001", "item": "Acme Running Shoes", "total": 89.99}'
   ```

2. **Expected API response** (HTTP 200):

   ```json
   {"message": "Order accepted", "orderId": "A-1001"}
   ```

3. **Validate DynamoDB:** DynamoDB > **Tables** > `AcmeCapstoneOrders` > **Explore table items**. **Expected:** an item with `orderId = A-1001`, `item = Acme Running Shoes`, `total = 89.99`.
4. **Validate SNS:** check your email. **Expected:** a message from `acme-capstone-notify` with subject **"Acme order received"** and body listing order `A-1001`, the item, and total.
5. **Validate logs (if anything failed):** Lambda > `acme-capstone-order` > **Monitor** > **View CloudWatch logs**. A successful run logs a `START`/`END`/`REPORT`; an `AccessDenied` error means the inline policy is wrong (see mistakes below).

---

## Concept Callouts

**AWS Mental Model:** An event flows through the **front door** (API Gateway), into **compute** (Lambda), which then updates **data** (DynamoDB) and sends a **notification** (SNS). Almost every serverless app is a variation of this "front door → compute → data + notify" pattern.

**What Is Happening Behind the Scenes?** The HTTP API delivers a **payload format 2.0** event; the body arrives as a JSON *string* in `event["body"]` (so your code must `json.loads` it). IAM is the invisible glue: API Gateway's resource-based permission lets it invoke Lambda, and the Lambda **execution role** authorizes the outbound `PutItem` and `Publish` calls.

**Common Beginner Mistake:**
- **Execution role missing DynamoDB/SNS permissions** → boto3 raises `AccessDenied` / `AccessDeniedException`. Always add the scoped inline policy (Part 4).
- **Wrong `TOPIC_ARN`** (typo, wrong account/region) → `sns:Publish` fails or targets nothing. Copy the exact ARN.
- **Not confirming the SNS email subscription** → publish succeeds but no email arrives.
- Trying to read the body from `event["orderId"]` directly — with payload v2.0 it lives in `event["body"]` as a string.

**Security Consideration:** The inline policy is scoped to the **specific table ARN and topic ARN** — least privilege. Never widen it to `"Resource": "*"` for convenience.

**Assessment Connection:** This capstone mirrors the graded serverless capstone: an API-triggered Lambda performing least-privilege cross-service writes. The same rubric (correct payload parsing, scoped IAM, working end-to-end flow) applies.

**Cost Awareness:** Every service here is **low cost / near-free at lab volume** — DynamoDB on-demand, a few Lambda invocations, a handful of SNS emails, and one HTTP API. There is **no idle monthly charge** like WAF, but you should still **delete everything** to keep the account clean and avoid surprise accumulation.

---

## Key Takeaways

- Serverless apps compose small services: **API Gateway → Lambda → DynamoDB + SNS**.
- HTTP APIs use **payload format 2.0**; the request body is a **string** in `event["body"]`.
- A Lambda **execution role** must explicitly allow each cross-service action, scoped to specific ARNs (**least privilege**).
- **Environment variables** decouple configuration from code.
- Validate end-to-end from **three angles**: API response, stored data (DynamoDB), and side effect (email).

---

## Cleanup Instructions

1. **Delete the HTTP API:** API Gateway > `acme-capstone-api` > **Delete**.
2. **Delete the Lambda function:** Lambda > `acme-capstone-order` > **Actions** > **Delete**.
3. **Delete the Lambda log group:** CloudWatch > **Log groups** > `/aws/lambda/acme-capstone-order` > **Delete**.
4. **Delete the execution role (optional, tidy):** IAM > **Roles** > find the auto-created `acme-capstone-order-role-xxxx` > **Delete** (this also removes the inline policy).
5. **Delete the DynamoDB table:** DynamoDB > `AcmeCapstoneOrders` > **Delete table** (uncheck backups if prompted).
6. **Delete the SNS topic + subscription:** SNS > **Subscriptions** > delete the email subscription; then **Topics** > `acme-capstone-notify` > **Delete**.
7. **(If you did the challenge) delete the CloudWatch alarm:** CloudWatch > **Alarms** > `acme-capstone-order-errors` > **Delete**.

---

## Early-Finisher Challenge

Reinforce **observability**: create a **CloudWatch alarm** that fires when the Lambda's **Errors** metric is **>= 1** in a 5-minute period, so the ops team is alerted whenever an order fails to process. Validate the alarm exists in **OK** state, then clean up.

---

## Challenge Solution

1. Open **CloudWatch** (region us-east-1) > **Alarms** > **All alarms** > **Create alarm**.
2. Choose **Select metric** > **Lambda** > **By Function Name** > find `acme-capstone-order` > check the **Errors** metric > **Select metric**.
3. **Specify metric and conditions:**
   - Statistic: **Sum**
   - Period: **5 minutes**
   - Threshold type: **Static**
   - Condition: **Greater/Equal** than **1** (i.e., `Errors >= 1`).
   - **Why Sum:** you want the *count* of errors in the window, not an average.
4. Choose **Next**.
5. **Notification:** choose **In alarm** state and select an SNS topic. You can reuse `acme-capstone-notify` (already confirmed) so alarm emails go to you. Choose **Next**.
6. Name: `acme-capstone-order-errors`. Choose **Next** > **Create alarm**.
7. **Validate:** on the **Alarms** list, `acme-capstone-order-errors` should appear and settle into **OK** (no recent errors).
   - *(Optional real trigger:* temporarily break the function — e.g., point `TOPIC_ARN` to a nonexistent ARN — send a `curl`, and within ~5 minutes the alarm flips to **In alarm** and emails you. Restore the correct ARN afterward.)
8. **Cleanup the challenge:** CloudWatch > **Alarms** > select `acme-capstone-order-errors` > **Delete**. Then complete the main **Cleanup Instructions** above.
