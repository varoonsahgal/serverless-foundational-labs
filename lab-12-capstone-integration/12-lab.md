# Lab 12: Capstone — Acme Retail Order Management System

## Estimated Duration

~120 minutes

## Scenario / Business Context

**Acme Retail** has grown from a small retailer to a mid-size e-commerce company. The existing order management system runs on aging on-premise servers, cannot handle Black Friday traffic spikes, and requires expensive maintenance contracts. The CTO has approved a full migration to AWS serverless architecture.

You are the lead cloud architect. Your job is to build the complete **Acme Retail Order Management System** using all the AWS services you've learned in Labs 01–11. This is not a toy — it is a production-representative architecture that:

- Accepts customer orders via a secured REST API.
- Authenticates customers using Cognito JWT tokens.
- Validates orders, checks inventory, and processes payments (simulated).
- Stores order and inventory data in DynamoDB.
- Orchestrates the full order workflow using Step Functions.
- Notifies the operations team via SNS.
- Queues fulfillment work for warehouse systems via SQS.
- Provides observability through CloudWatch dashboards and alarms.
- Protects the API from malicious traffic with WAF.

By the end of this lab, you will have placed a real order through the API and traced it through every service — from HTTP request to warehouse fulfillment queue.

---

## System Architecture

```
                                    ┌──────────────┐
                                    │   AWS WAF    │
                                    │  Web ACL     │
                                    └──────┬───────┘
                                           │ (inspects every request)
                                           ▼
┌─────────┐   POST /order        ┌──────────────────┐
│ Customer│ ────────────────────► │  API Gateway     │
│  (curl) │   (JWT required)     │  REST API        │
└─────────┘                      │  us-west-2       │
                                 └────────┬─────────┘
                                          │
                               ┌──────────▼──────────┐
                               │  Cognito Authorizer  │
                               │  (JWT validation)    │
                               └──────────┬──────────┘
                                          │ (authorized request)
                                          ▼
                                 ┌─────────────────┐
                                 │  Lambda         │
                                 │ acme-order-api  │
                                 └────────┬────────┘
                                          │ (starts workflow)
                                          ▼
                                 ┌─────────────────┐
                                 │  Step Functions │
                                 │  Order Workflow  │
                                 └────────┬────────┘
                                          │
                    ┌─────────────────────┼──────────────────────┐
                    │                     │                       │
                    ▼                     ▼                       ▼
           ┌──────────────┐     ┌──────────────────┐    ┌──────────────┐
           │   Lambda     │     │    DynamoDB      │    │  Lambda      │
           │ acme-validate│     │  AcmeOrders      │    │ acme-notify  │
           │  -order      │     │  AcmeProducts    │    │              │
           └──────────────┘     └──────────────────┘    └──────┬───────┘
                                                                │
                                                     ┌──────────▼──────────┐
                                                     │  SNS                │
                                                     │  acme-order-notify  │
                                                     └──────────┬──────────┘
                                                                │
                                              ┌─────────────────┤
                                              │                 │
                                              ▼                 ▼
                                    ┌───────────────┐  ┌───────────────┐
                                    │  Email (ops)  │  │  SQS Queue    │
                                    │  subscription │  │ acme-fulfil.. │
                                    └───────────────┘  └───────┬───────┘
                                                               │
                                                     ┌─────────▼─────────┐
                                                     │  Lambda           │
                                                     │ acme-fulfillment  │
                                                     └───────────────────┘
```

---

## Learning Objectives

By the end of this lab you will be able to:

- Compose a multi-service serverless architecture where each service has a specific responsibility.
- Apply **least-privilege IAM** at each service boundary (every role scoped to specific ARNs).
- Design DynamoDB tables with appropriate keys and GSIs for real query patterns.
- Build API Gateway REST API with Cognito JWT authorization.
- Orchestrate multi-step workflows with Step Functions (including Choice, Catch, and Wait states).
- Chain SNS → SQS for fan-out with buffering.
- Deploy WAF to protect the checkout API.
- Create a CloudWatch dashboard with key metrics from all services.
- Execute an end-to-end trace: place order → track through every service → validate final state.

---

## AWS Services Used (Mapping to Labs 01–11)

| Service | Lab Origin | Role in This System |
|---|---|---|
| IAM | Lab 01 | Service roles for every Lambda, Step Functions, CodePipeline |
| DynamoDB | Lab 02 | Orders table + Products/Inventory table |
| Lambda | Lab 03 | API handler, validator, notifier, fulfillment processor |
| API Gateway | Lab 04 | REST API: POST /order, GET /order/{orderId}, GET /products |
| Cognito | Lab 05 | User pool + JWT authorizer on POST /order |
| SNS | Lab 06 | Order notification topic (email + SQS subscriber) |
| SQS | Lab 07 | Fulfillment queue + Dead-letter queue |
| Step Functions | Lab 08 | Order workflow state machine |
| CloudWatch | Lab 09 | Dashboard, alarms, metric filters |
| WAF | Lab 10 | Protect the REST API |
| CodePipeline | Lab 11 | Automated deployment of Lambda functions |

---

## Prerequisites

- An AWS account. Region: **US West (Oregon) `us-west-2`**.
- IAM user with broad permissions for all services above.
- Terminal with `curl`, `python3`, and `aws` CLI configured.
- An email address you can check (for SNS confirmations).
- Completed or familiar with Labs 01–11.

> **Time management tip:** This lab has 10 build phases. Each phase validates before you proceed to the next. Do not skip validation steps — integration bugs are much harder to debug after the fact than if you catch them service by service.

---

## Phase 1 — IAM: Create Service Roles

Create all IAM roles upfront so you can reference their ARNs in later phases.

> **Security Consideration:** In this lab, all IAM resource ARNs use your specific account ID and region (`us-west-2`). Replace `<ACCOUNT_ID>` with your 12-digit account ID throughout. Never use `Resource: "*"` for cross-service permissions in production.

### 1A — Lambda Execution Role: acme-order-api

This role is used by the Lambda function that handles API requests.

1. IAM > **Roles** > **Create role** > **AWS service** > **Lambda**.
2. **Role name**: `acme-order-api-role`
3. After creation, add an inline policy named `acme-order-api-policy`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "DynamoDBOrdersWrite",
         "Effect": "Allow",
         "Action": ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"],
         "Resource": "arn:aws:dynamodb:us-west-2:<ACCOUNT_ID>:table/AcmeOrders"
       },
       {
         "Sid": "DynamoDBProductsRead",
         "Effect": "Allow",
         "Action": ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"],
         "Resource": [
           "arn:aws:dynamodb:us-west-2:<ACCOUNT_ID>:table/AcmeProducts",
           "arn:aws:dynamodb:us-west-2:<ACCOUNT_ID>:table/AcmeProducts/index/*"
         ]
       },
       {
         "Sid": "StepFunctionsStart",
         "Effect": "Allow",
         "Action": "states:StartExecution",
         "Resource": "arn:aws:states:us-west-2:<ACCOUNT_ID>:stateMachine:AcmeOrderWorkflow"
       },
       {
         "Sid": "CloudWatchLogs",
         "Effect": "Allow",
         "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
         "Resource": "arn:aws:logs:us-west-2:<ACCOUNT_ID>:log-group:/aws/lambda/acme-order-api:*"
       }
     ]
   }
   ```

### 1B — Lambda Execution Role: acme-fulfillment

Used by the Lambda function that processes SQS fulfillment messages.

1. IAM > **Roles** > **Create role** > **Lambda** > **Role name**: `acme-fulfillment-role`.
2. Inline policy `acme-fulfillment-policy`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "SQSReceive",
         "Effect": "Allow",
         "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"],
         "Resource": "arn:aws:sqs:us-west-2:<ACCOUNT_ID>:acme-fulfillment-queue"
       },
       {
         "Sid": "DynamoDBOrderUpdate",
         "Effect": "Allow",
         "Action": ["dynamodb:UpdateItem", "dynamodb:GetItem"],
         "Resource": "arn:aws:dynamodb:us-west-2:<ACCOUNT_ID>:table/AcmeOrders"
       },
       {
         "Sid": "CloudWatchLogs",
         "Effect": "Allow",
         "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
         "Resource": "arn:aws:logs:us-west-2:<ACCOUNT_ID>:log-group:/aws/lambda/acme-fulfillment:*"
       }
     ]
   }
   ```

### 1C — Step Functions Execution Role

Used by the Step Functions state machine to invoke Lambda functions and write to DynamoDB.

1. IAM > **Roles** > **Create role** > **AWS service** > choose **Step Functions** in the use case.
2. **Role name**: `acme-step-functions-role`.
3. Inline policy `acme-step-functions-policy`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "InvokeLambda",
         "Effect": "Allow",
         "Action": "lambda:InvokeFunction",
         "Resource": [
           "arn:aws:lambda:us-west-2:<ACCOUNT_ID>:function:acme-order-validator",
           "arn:aws:lambda:us-west-2:<ACCOUNT_ID>:function:acme-order-notifier"
         ]
       },
       {
         "Sid": "DynamoDBOrders",
         "Effect": "Allow",
         "Action": ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"],
         "Resource": "arn:aws:dynamodb:us-west-2:<ACCOUNT_ID>:table/AcmeOrders"
       },
       {
         "Sid": "SNSPublish",
         "Effect": "Allow",
         "Action": "sns:Publish",
         "Resource": "arn:aws:sns:us-west-2:<ACCOUNT_ID>:acme-order-notify"
       },
       {
         "Sid": "SQSSend",
         "Effect": "Allow",
         "Action": "sqs:SendMessage",
         "Resource": "arn:aws:sqs:us-west-2:<ACCOUNT_ID>:acme-fulfillment-queue"
       },
       {
         "Sid": "CloudWatchLogs",
         "Effect": "Allow",
         "Action": ["logs:CreateLogDelivery", "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"],
         "Resource": "*"
       }
     ]
   }
   ```

### Validation Checkpoint: Phase 1

- [ ] Role `acme-order-api-role` exists with inline policy `acme-order-api-policy`.
- [ ] Role `acme-fulfillment-role` exists with inline policy `acme-fulfillment-policy`.
- [ ] Role `acme-step-functions-role` exists with inline policy `acme-step-functions-policy`.

---

## Phase 2 — DynamoDB: Products and Orders Tables

### 2A — AcmeProducts Table

Stores product catalog and inventory.

1. DynamoDB > **Create table**.
2. Configure:
   - **Table name**: `AcmeProducts`
   - **Partition key**: `productId` (String)
   - **Table settings**: Customize settings
   - **Capacity mode**: On-demand
3. Choose **Create table**.
4. Once Active, add a **Global Secondary Index (GSI)** for category queries:
   - **Indexes** tab > **Create index**.
   - **Partition key**: `category` (String)
   - **Sort key**: `price` (Number)
   - **Index name**: `category-price-index`
   - Choose **Create index**. Wait for status to become Active.

   > **Why this GSI?** The Acme product catalog API needs to support queries like "show me all shoes sorted by price." Without a GSI, you'd have to scan the entire table. The `category-price-index` lets you run `Query` with `category = "shoes"` sorted by `price` — efficient and cost-effective.

5. Seed the table with sample inventory. Go to **Explore table items** > **Create item** > switch to **JSON** view. Add each item:

   ```json
   {"productId": {"S": "SHOES-001"}, "name": {"S": "Acme Trail Runner"}, "category": {"S": "shoes"}, "price": {"N": "89.99"}, "inventory": {"N": "150"}, "status": {"S": "IN_STOCK"}}
   ```
   ```json
   {"productId": {"S": "SHIRT-001"}, "name": {"S": "Acme Performance Polo"}, "category": {"S": "shirts"}, "price": {"N": "34.99"}, "inventory": {"N": "500"}, "status": {"S": "IN_STOCK"}}
   ```
   ```json
   {"productId": {"S": "JACKET-001"}, "name": {"S": "Acme Winter Parka"}, "category": {"S": "jackets"}, "price": {"N": "199.99"}, "inventory": {"N": "0"}, "status": {"S": "OUT_OF_STOCK"}}
   ```

### 2B — AcmeOrders Table

Stores all customer orders.

1. DynamoDB > **Create table**.
2. Configure:
   - **Table name**: `AcmeOrders`
   - **Partition key**: `orderId` (String)
   - **Sort key**: `customerId` (String)
     - Including `customerId` as the sort key enables efficient queries like "get all orders for customer X" using `Query` with `orderId` as a prefix and `customerId` as a filter. In practice, you might use `customerId` as PK with `orderId` as SK — but for this lab PK=orderId enables direct lookups by order ID.
   - **Capacity mode**: On-demand
3. Choose **Create table**.
4. Add a GSI for customer order history:
   - **Indexes** tab > **Create index**.
   - **Partition key**: `customerId` (String)
   - **Sort key**: `createdAt` (String)
   - **Index name**: `customer-orders-index`
   - **Projected attributes**: All
   - Choose **Create index**.

### Validation Checkpoint: Phase 2

- [ ] `AcmeProducts` table Active with `category-price-index` GSI Active.
- [ ] 3 seed items in AcmeProducts (SHOES-001, SHIRT-001, JACKET-001).
- [ ] `AcmeOrders` table Active with `customer-orders-index` GSI Active.

---

## Phase 3 — SNS and SQS: Notification and Fulfillment Plumbing

Build the notification and queuing infrastructure before the Lambda functions that use it.

### 3A — Dead-Letter Queue

1. SQS > **Create queue**.
2. **Type**: Standard. **Name**: `acme-fulfillment-dlq`.
3. Leave defaults. **Create queue**. Note the ARN.

> **Why a DLQ?** If the fulfillment Lambda fails to process a message (e.g., database unavailable), SQS retries it up to the configured maximum. After that, the message moves to the DLQ instead of being lost. The ops team can inspect DLQ messages, fix the root cause, and reprocess them. Without a DLQ, unprocessable messages disappear silently.

### 3B — Fulfillment Queue

1. SQS > **Create queue**.
2. **Type**: Standard. **Name**: `acme-fulfillment-queue`.
3. Customize settings:
   - **Visibility timeout**: 30 seconds
     - How long a received message is hidden from other consumers while being processed. Set it longer than your Lambda timeout (default 3s). 30s is safe for this lab.
   - **Message retention period**: 4 days
   - **Dead-letter queue**: enable. Select `acme-fulfillment-dlq`. **Maximum receives**: 3.
     - After 3 failed processing attempts, the message moves to the DLQ.
4. **Create queue**. Note the ARN.

### 3C — SNS Order Notification Topic

1. SNS > **Topics** > **Create topic**. **Type**: Standard. **Name**: `acme-order-notify`.
2. **Create topic**. Note the ARN.
3. **Email subscription** (ops team alert):
   - **Create subscription** > Protocol **Email** > Endpoint: your email.
   - Confirm via email.
4. **SQS subscription** (fulfillment fan-out):
   - **Create subscription** > Protocol **Amazon SQS** > Endpoint: ARN of `acme-fulfillment-queue`.
   - Choose **Create subscription**.
5. **Grant SNS permission to send to the SQS queue:**
   - Open `acme-fulfillment-queue` in SQS.
   - **Access policy** tab > **Edit**.
   - Add a statement allowing SNS to send messages:
     ```json
     {
       "Sid": "AllowSNSPublish",
       "Effect": "Allow",
       "Principal": {"Service": "sns.amazonaws.com"},
       "Action": "sqs:SendMessage",
       "Resource": "arn:aws:sqs:us-west-2:<ACCOUNT_ID>:acme-fulfillment-queue",
       "Condition": {
         "ArnEquals": {
           "aws:SourceArn": "arn:aws:sns:us-west-2:<ACCOUNT_ID>:acme-order-notify"
         }
       }
     }
     ```
   - Add this statement to the existing policy array. **Save**.

> **Why SNS → SQS (Fan-Out)?** SNS can have multiple subscriptions. When an order is placed, one `Publish` call to SNS simultaneously: (1) emails the ops team and (2) puts a message in the fulfillment queue. The fulfillment queue adds **buffering** — if the fulfillment Lambda is down or slow, messages accumulate in the queue and are processed when it recovers. SNS alone has no buffering; SQS adds durability.

### Validation Checkpoint: Phase 3

- [ ] `acme-fulfillment-dlq` SQS queue created.
- [ ] `acme-fulfillment-queue` with DLQ and 30s visibility timeout created.
- [ ] `acme-order-notify` SNS topic created.
- [ ] SNS has email subscription (Confirmed) and SQS subscription.
- [ ] SQS queue access policy allows SNS to send messages.

---

## Phase 4 — Cognito: Customer Authentication

### 4A — Create User Pool

1. Cognito > **User pools** > **Create user pool**.
2. Configure:
   - **Sign-in options**: Email.
   - **Password policy**: Cognito defaults.
   - **MFA**: No MFA (lab simplicity).
   - **User pool name**: `AcmeRetailUsers`.
3. **App clients**:
   - Add an app client named `acme-retail-app`.
   - **Client secret**: Generate a client secret — NO. For SPA/mobile/CLI testing, use a public client (no secret).
   - **Auth flows**: Enable `ALLOW_USER_PASSWORD_AUTH`, `ALLOW_USER_SRP_AUTH`, `ALLOW_REFRESH_TOKEN_AUTH`.
4. Complete creation. Note:
   - **User pool ID**: `us-west-2_xxxxxxxxx`
   - **Client ID**: `xxxxxxxxxxxxxxxxxxxxxxxx`

### 4B — Create a Test User

1. Cognito > your user pool > **Users** > **Create user**.
2. Configure:
   - **Invitation type**: Don't send invitation.
   - **Username**: `testcustomer`
   - **Email**: your email, mark as verified.
   - **Temporary password**: `TempPass123!`
3. Create user.
4. **Force-confirm the password** (required for programmatic auth):
   ```bash
   aws cognito-idp admin-set-user-password \
     --user-pool-id us-west-2_XXXXXXXXX \
     --username testcustomer \
     --password "PermanentPass456!" \
     --permanent \
     --region us-west-2
   ```
   Replace `us-west-2_XXXXXXXXX` with your user pool ID.

### 4C — Get a JWT Token

You'll use this token to call the secured API in Phase 8 (testing).

```bash
aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id <YOUR_CLIENT_ID> \
  --auth-parameters USERNAME=testcustomer,PASSWORD="PermanentPass456!" \
  --region us-west-2 \
  --query 'AuthenticationResult.IdToken' \
  --output text
```

Save the output — this is your JWT token. It expires in 1 hour. **Store it in a shell variable:**

```bash
export JWT_TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id <YOUR_CLIENT_ID> \
  --auth-parameters USERNAME=testcustomer,PASSWORD="PermanentPass456!" \
  --region us-west-2 \
  --query 'AuthenticationResult.IdToken' \
  --output text)
echo "Token: ${JWT_TOKEN:0:50}..."  # Preview first 50 chars
```

### Validation Checkpoint: Phase 4

- [ ] `AcmeRetailUsers` user pool created in `us-west-2`.
- [ ] `acme-retail-app` client ID noted.
- [ ] `testcustomer` user created and password confirmed.
- [ ] JWT token successfully retrieved and stored in `$JWT_TOKEN`.

---

## Phase 5 — Lambda Functions

Create three Lambda functions. All use Python 3.12, all in `us-west-2`.

### 5A — acme-order-api (API Handler)

This is the main API Lambda — receives HTTP requests from API Gateway.

1. Lambda > **Create function** > **Author from scratch**:
   - Name: `acme-order-api`, Runtime: Python 3.12, Execution role: `acme-order-api-role`.

2. Code (replace the default `lambda_function.py`):

```python
import json
import os
import boto3
import uuid
from datetime import datetime, timezone

dynamodb = boto3.client("dynamodb", region_name="us-west-2")
sfn = boto3.client("stepfunctions", region_name="us-west-2")

ORDERS_TABLE = os.environ.get("ORDERS_TABLE", "AcmeOrders")
PRODUCTS_TABLE = os.environ.get("PRODUCTS_TABLE", "AcmeProducts")
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]


def lambda_handler(event, context):
    method = event.get("httpMethod", "")
    path = event.get("path", "")

    # Route: GET /products
    if method == "GET" and path == "/prod/products":
        return get_products()

    # Route: GET /order/{orderId}
    if method == "GET" and path.startswith("/prod/order/"):
        order_id = path.split("/")[-1]
        return get_order(order_id)

    # Route: POST /order
    if method == "POST" and path == "/prod/order":
        return create_order(event)

    return _response(404, {"error": "Route not found", "path": path, "method": method})


def get_products():
    resp = dynamodb.scan(TableName=PRODUCTS_TABLE)
    items = [_unmarshal(item) for item in resp.get("Items", [])]
    return _response(200, {"products": items, "count": len(items)})


def get_order(order_id):
    resp = dynamodb.get_item(
        TableName=ORDERS_TABLE,
        Key={"orderId": {"S": order_id}, "customerId": {"S": "UNKNOWN"}}
    )
    # Note: in a real system, customerId would come from the JWT claims.
    # For this lab, scan for the order by orderId.
    scan_resp = dynamodb.scan(
        TableName=ORDERS_TABLE,
        FilterExpression="orderId = :oid",
        ExpressionAttributeValues={":oid": {"S": order_id}}
    )
    items = scan_resp.get("Items", [])
    if not items:
        return _response(404, {"error": f"Order {order_id} not found"})
    return _response(200, {"order": _unmarshal(items[0])})


def create_order(event):
    raw_body = event.get("body") or "{}"
    try:
        data = json.loads(raw_body)
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON body"})

    product_id = data.get("productId")
    quantity = data.get("quantity", 1)
    # Extract customerId from Cognito JWT claims (API Gateway injects these)
    claims = event.get("requestContext", {}).get("authorizer", {}).get("claims", {})
    customer_id = claims.get("sub") or claims.get("email") or data.get("customerId", "GUEST")

    if not product_id:
        return _response(400, {"error": "productId is required"})
    if not isinstance(quantity, int) or quantity < 1:
        return _response(400, {"error": "quantity must be a positive integer"})

    # Check product exists
    product_resp = dynamodb.get_item(
        TableName=PRODUCTS_TABLE,
        Key={"productId": {"S": product_id}}
    )
    product = product_resp.get("Item")
    if not product:
        return _response(404, {"error": f"Product {product_id} not found"})

    product_data = _unmarshal(product)

    # Generate order ID
    order_id = f"ORD-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}-{str(uuid.uuid4())[:8].upper()}"
    created_at = datetime.now(timezone.utc).isoformat()
    total = float(product_data.get("price", 0)) * quantity

    # Write initial order to DynamoDB with status PENDING
    dynamodb.put_item(
        TableName=ORDERS_TABLE,
        Item={
            "orderId": {"S": order_id},
            "customerId": {"S": customer_id},
            "productId": {"S": product_id},
            "productName": {"S": product_data.get("name", "Unknown")},
            "quantity": {"N": str(quantity)},
            "total": {"N": str(total)},
            "status": {"S": "PENDING"},
            "createdAt": {"S": created_at}
        }
    )

    # Start Step Functions execution
    execution_input = json.dumps({
        "orderId": order_id,
        "customerId": customer_id,
        "productId": product_id,
        "quantity": quantity,
        "total": total,
        "createdAt": created_at
    })
    sfn.start_execution(
        stateMachineArn=STATE_MACHINE_ARN,
        name=order_id,
        input=execution_input
    )

    return _response(202, {
        "message": "Order received and processing",
        "orderId": order_id,
        "status": "PENDING",
        "total": total
    })


def _unmarshal(item):
    """Convert DynamoDB low-level format to plain dict."""
    result = {}
    for key, value in item.items():
        if "S" in value:
            result[key] = value["S"]
        elif "N" in value:
            result[key] = float(value["N"]) if "." in value["N"] else int(value["N"])
        elif "BOOL" in value:
            result[key] = value["BOOL"]
        else:
            result[key] = str(value)
    return result


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body)
    }
```

3. Set **environment variables** (Configuration > Environment variables):
   - `ORDERS_TABLE` = `AcmeOrders`
   - `PRODUCTS_TABLE` = `AcmeProducts`
   - `STATE_MACHINE_ARN` = (leave blank for now — fill in after Step Functions is created in Phase 6)

4. Set **timeout** to 10 seconds (default is 3s — Step Functions start can take a moment).

### 5B — acme-order-validator

This Lambda is invoked by Step Functions to validate the order (check inventory).

1. Lambda > **Create function**: Name `acme-order-validator`, Python 3.12, new execution role `acme-validator-role`.
2. Add inline policy to `acme-validator-role`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {"Effect": "Allow", "Action": ["dynamodb:GetItem", "dynamodb:UpdateItem"],
        "Resource": "arn:aws:dynamodb:us-west-2:<ACCOUNT_ID>:table/AcmeProducts"},
       {"Effect": "Allow", "Action": ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
        "Resource": "arn:aws:logs:us-west-2:<ACCOUNT_ID>:log-group:/aws/lambda/acme-order-validator:*"}
     ]
   }
   ```
3. Code:
   ```python
   import boto3

   dynamodb = boto3.client("dynamodb", region_name="us-west-2")
   PRODUCTS_TABLE = "AcmeProducts"

   def lambda_handler(event, context):
       product_id = event["productId"]
       quantity = int(event["quantity"])

       resp = dynamodb.get_item(
           TableName=PRODUCTS_TABLE,
           Key={"productId": {"S": product_id}}
       )
       item = resp.get("Item")
       if not item:
           return {**event, "validationStatus": "FAILED", "reason": "Product not found"}

       inventory = int(item.get("inventory", {}).get("N", "0"))
       product_status = item.get("status", {}).get("S", "UNKNOWN")

       if product_status == "OUT_OF_STOCK" or inventory < quantity:
           return {**event, "validationStatus": "FAILED",
                   "reason": f"Insufficient inventory: {inventory} available, {quantity} requested"}

       return {**event, "validationStatus": "PASSED", "availableInventory": inventory}
   ```
4. Deploy.

### 5C — acme-order-notifier

This Lambda publishes SNS and SQS messages when an order completes.

1. Lambda > **Create function**: Name `acme-order-notifier`, Python 3.12, new role `acme-notifier-role`.
2. Add inline policy to `acme-notifier-role`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {"Effect": "Allow", "Action": "sns:Publish",
        "Resource": "arn:aws:sns:us-west-2:<ACCOUNT_ID>:acme-order-notify"},
       {"Effect": "Allow", "Action": "sqs:SendMessage",
        "Resource": "arn:aws:sqs:us-west-2:<ACCOUNT_ID>:acme-fulfillment-queue"},
       {"Effect": "Allow", "Action": ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
        "Resource": "arn:aws:logs:us-west-2:<ACCOUNT_ID>:log-group:/aws/lambda/acme-order-notifier:*"}
     ]
   }
   ```
3. Set environment variables: `SNS_TOPIC_ARN` = SNS topic ARN. `SQS_QUEUE_URL` = fulfillment queue URL.
4. Code:
   ```python
   import boto3
   import json
   import os

   sns = boto3.client("sns", region_name="us-west-2")
   sqs = boto3.client("sqs", region_name="us-west-2")
   SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
   SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]

   def lambda_handler(event, context):
       order_id = event["orderId"]
       customer_id = event["customerId"]
       product_id = event["productId"]
       total = event["total"]
       status = event.get("orderStatus", "PROCESSING")

       message = (f"Acme Retail Order Update\n"
                  f"Order ID: {order_id}\n"
                  f"Customer: {customer_id}\n"
                  f"Product: {product_id}\n"
                  f"Total: ${total:.2f}\n"
                  f"Status: {status}")

       sns.publish(
           TopicArn=SNS_TOPIC_ARN,
           Subject=f"Order {order_id} — {status}",
           Message=message
       )

       sqs.send_message(
           QueueUrl=SQS_QUEUE_URL,
           MessageBody=json.dumps({
               "orderId": order_id,
               "customerId": customer_id,
               "productId": product_id,
               "total": total,
               "action": "FULFILL"
           })
       )

       return {**event, "notificationSent": True}
   ```
5. Deploy.

### 5D — acme-fulfillment

Processes SQS fulfillment messages (triggered by SQS event source mapping).

1. Lambda > **Create function**: Name `acme-fulfillment`, Python 3.12, role `acme-fulfillment-role`.
2. Code:
   ```python
   import boto3
   import json

   dynamodb = boto3.client("dynamodb", region_name="us-west-2")
   ORDERS_TABLE = "AcmeOrders"

   def lambda_handler(event, context):
       for record in event["Records"]:
           # SQS messages from SNS are double-wrapped
           outer = json.loads(record["body"])
           if "Message" in outer:
               # SNS-wrapped message
               body = json.loads(outer["Message"])
           else:
               body = outer

           order_id = body["orderId"]
           customer_id = body.get("customerId", "UNKNOWN")

           # Simulate fulfillment: update order status to FULFILLED
           dynamodb.update_item(
               TableName=ORDERS_TABLE,
               Key={"orderId": {"S": order_id}, "customerId": {"S": customer_id}},
               UpdateExpression="SET #s = :s",
               ExpressionAttributeNames={"#s": "status"},
               ExpressionAttributeValues={":s": {"S": "FULFILLED"}}
           )
           print(f"Order {order_id} fulfilled.")

       return {"statusCode": 200, "processed": len(event["Records"])}
   ```
3. Deploy.
4. **Add SQS trigger:**
   - Lambda > `acme-fulfillment` > **Add trigger** > **SQS** > select `acme-fulfillment-queue`.
   - **Batch size**: 5. **Enabled**: yes.
   - Add trigger.

### Validation Checkpoint: Phase 5

- [ ] `acme-order-api` deployed with correct environment variables.
- [ ] `acme-order-validator` deployed.
- [ ] `acme-order-notifier` deployed with SNS and SQS env vars set.
- [ ] `acme-fulfillment` deployed with SQS event source mapping to `acme-fulfillment-queue`.

---

## Phase 6 — Step Functions: Order Workflow

### 6A — Create the State Machine

1. Step Functions > **State machines** > **Create state machine**.
2. Choose **Write your workflow in code** (JSON/Amazon States Language).
3. **Type**: Standard (not Express — Standard keeps execution history for 90 days, essential for debugging).
4. Paste this state machine definition:

```json
{
  "Comment": "Acme Retail Order Processing Workflow",
  "StartAt": "ValidateOrder",
  "States": {
    "ValidateOrder": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:us-west-2:<ACCOUNT_ID>:function:acme-order-validator",
      "ResultPath": "$",
      "Next": "CheckValidation",
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "Next": "OrderFailed",
          "ResultPath": "$.error"
        }
      ]
    },
    "CheckValidation": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.validationStatus",
          "StringEquals": "PASSED",
          "Next": "ProcessOrder"
        }
      ],
      "Default": "OrderRejected"
    },
    "ProcessOrder": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "AcmeOrders",
        "Key": {
          "orderId": {"S.$": "$.orderId"},
          "customerId": {"S.$": "$.customerId"}
        },
        "UpdateExpression": "SET #s = :s",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {":s": {"S": "PROCESSING"}}
      },
      "ResultPath": "$.dynamoResult",
      "Next": "NotifyAndFulfill",
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "Next": "OrderFailed",
          "ResultPath": "$.error"
        }
      ]
    },
    "NotifyAndFulfill": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:us-west-2:<ACCOUNT_ID>:function:acme-order-notifier",
      "Parameters": {
        "orderId.$": "$.orderId",
        "customerId.$": "$.customerId",
        "productId.$": "$.productId",
        "total.$": "$.total",
        "orderStatus": "PROCESSING"
      },
      "ResultPath": "$.notifyResult",
      "Next": "OrderComplete",
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "Next": "OrderFailed",
          "ResultPath": "$.error"
        }
      ]
    },
    "OrderComplete": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "AcmeOrders",
        "Key": {
          "orderId": {"S.$": "$.orderId"},
          "customerId": {"S.$": "$.customerId"}
        },
        "UpdateExpression": "SET #s = :s",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {":s": {"S": "COMPLETED"}}
      },
      "ResultPath": "$.finalUpdate",
      "End": true
    },
    "OrderRejected": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "AcmeOrders",
        "Key": {
          "orderId": {"S.$": "$.orderId"},
          "customerId": {"S.$": "$.customerId"}
        },
        "UpdateExpression": "SET #s = :s, rejectionReason = :r",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {
          ":s": {"S": "REJECTED"},
          ":r": {"S.$": "$.reason"}
        }
      },
      "End": true
    },
    "OrderFailed": {
      "Type": "Fail",
      "Error": "OrderProcessingFailed",
      "Cause": "An unexpected error occurred during order processing"
    }
  }
}
```

Replace both `<ACCOUNT_ID>` occurrences with your account ID.

5. **Configuration**:
   - **State machine name**: `AcmeOrderWorkflow`
   - **Execution role**: `acme-step-functions-role`
   - **Logging**: Enable logging to CloudWatch Logs (log level: ALL). Create a new log group `/aws/states/AcmeOrderWorkflow`.
6. Choose **Create state machine**. Note the state machine ARN.

### 6B — Update the API Lambda Environment Variable

Now that the state machine ARN is known, update `acme-order-api`:
1. Lambda > `acme-order-api` > **Configuration** > **Environment variables** > **Edit**.
2. Set `STATE_MACHINE_ARN` = `arn:aws:states:us-west-2:<ACCOUNT_ID>:stateMachine:AcmeOrderWorkflow`.
3. **Save**.

### Validation Checkpoint: Phase 6

- [ ] `AcmeOrderWorkflow` state machine created with Standard type.
- [ ] State machine ARN updated in `acme-order-api` environment variables.
- [ ] Step Functions execution role is `acme-step-functions-role`.

---

## Phase 7 — API Gateway: REST API with Cognito Authorizer

### 7A — Create the REST API

1. API Gateway > **Create API** > **REST API** > **Build**.
2. **New API**. Name: `acme-retail-api`. Endpoint type: **Regional**. **Create API**.

### 7B — Create Resources and Methods

Create `/products` and `/order` resources with appropriate methods.

**GET /products** (unauthenticated — browse catalog):
1. Resources > create resource: `/products`.
2. Add method: GET, integration: Lambda proxy, function: `acme-order-api`. **Save**.

**POST /order** (authenticated — requires JWT):
1. Resources > create resource: `/order`.
2. Add method: POST, integration: Lambda proxy, function: `acme-order-api`. **Save**.

**GET /order/{orderId}** (order lookup):
1. Under `/order`, create resource: `{orderId}` (this is a path parameter).
2. Add method: GET, integration: Lambda proxy, function: `acme-order-api`. **Save**.

### 7C — Create Cognito Authorizer

1. API Gateway > left nav: **Authorizers** > **Create authorizer**.
2. Configure:
   - **Authorizer name**: `CognitoJWT`
   - **Type**: Cognito
   - **Cognito user pool**: select `AcmeRetailUsers` (in `us-west-2`)
   - **Token source**: `Authorization` (the HTTP header name)
   - **Token validation**: leave blank (validates automatically against the user pool)
3. **Create authorizer**.
4. Test the authorizer: paste your `$JWT_TOKEN` and choose **Test**. Expected: HTTP 200, with claims showing `sub`, `email`, and other JWT fields.

### 7D — Apply Authorizer to POST /order

1. Resources > `/order` > POST > **Method Request**.
2. **Authorization**: select `CognitoJWT`.
3. **Save**.

### 7E — Deploy the API

1. **Deploy API** > Stage: **[New Stage]**, name: `prod`. **Deploy**.
2. Note the Invoke URL: `https://<api-id>.execute-api.us-west-2.amazonaws.com/prod`.

### Validation Checkpoint: Phase 7

- [ ] `acme-retail-api` has 3 methods: GET /products, POST /order, GET /order/{orderId}.
- [ ] POST /order has `CognitoJWT` authorizer applied.
- [ ] API deployed to `prod` stage.
- [ ] Invoke URL noted.

---

## Phase 8 — WAF: Protect the API

1. WAF & Shield > **Web ACLs** > **Create web ACL**.
2. **Scope**: Regional. **Region**: US West (Oregon).
3. **Name**: `acme-retail-web-acl`. **Associate**: API Gateway `acme-retail-api` prod stage.
4. Add rules:
   - `AWSManagedRulesAmazonIpReputationList` (Block, priority 0)
   - `AWSManagedRulesSQLiRuleSet` (Block, priority 1)
   - `AWSManagedRulesKnownBadInputsRuleSet` (Count, priority 2 — observe first)
5. **Default action**: Allow.
6. **Create web ACL**.

> **Why minimal WAF here?** The full WAF setup was covered in Lab 10. For the capstone, apply the most impactful rules (SQLi, reputation) without over-engineering. In production you'd add CRS, rate limiting, and Bot Control after baseline monitoring.

---

## Phase 9 — CloudWatch: Observability Dashboard

Create a dashboard that gives Acme ops team visibility into the full system.

1. CloudWatch > **Dashboards** > **Create dashboard**.
2. Name: `AcmeRetailOps`. Choose **Create dashboard**.
3. Add the following widgets:

**Widget 1: Lambda Invocations (Line chart)**
- Metrics: Lambda > `acme-order-api` > Invocations, Errors, Duration (Average)
- Period: 1 minute. Statistics: Sum for Invocations/Errors, Average for Duration.

**Widget 2: Step Functions Executions (Number widgets)**
- Metrics: Step Functions > `AcmeOrderWorkflow` > ExecutionsStarted, ExecutionsSucceeded, ExecutionsFailed
- Period: 5 minutes.

**Widget 3: SQS Queue Depth (Line chart)**
- Metrics: SQS > `acme-fulfillment-queue` > ApproximateNumberOfMessagesVisible
- Metric: SQS > `acme-fulfillment-dlq` > ApproximateNumberOfMessagesVisible
- Period: 1 minute.

**Widget 4: DynamoDB Read/Write Capacity (Line chart)**
- Metrics: DynamoDB > `AcmeOrders` > ConsumedReadCapacityUnits, ConsumedWriteCapacityUnits
- Period: 1 minute.

4. **Save dashboard**.

### 9B — Create Critical Alarms

**Alarm 1: Lambda Error Rate**
1. CloudWatch > **Alarms** > **Create alarm** > **Lambda** > `acme-order-api` > **Errors**.
2. Statistic: Sum. Period: 5 minutes. Threshold: >= 3 errors.
3. **Actions**: **In alarm** → send to SNS `acme-order-notify`.
4. Alarm name: `acme-order-api-errors`.

**Alarm 2: Fulfillment DLQ Messages**
1. **Create alarm** > SQS > `acme-fulfillment-dlq` > **ApproximateNumberOfMessagesVisible**.
2. Statistic: Maximum. Period: 5 minutes. Threshold: >= 1.
3. **Actions**: **In alarm** → send to SNS `acme-order-notify`.
4. Alarm name: `acme-fulfillment-dlq-messages`.
   > This alarm fires the moment any message ends up in the DLQ — meaning a fulfillment job failed 3 times. Ops team gets an immediate alert.

### Validation Checkpoint: Phase 9

- [ ] `AcmeRetailOps` dashboard exists with 4 widgets.
- [ ] `acme-order-api-errors` alarm in OK state.
- [ ] `acme-fulfillment-dlq-messages` alarm in OK state.

---

## Phase 10 — End-to-End Test

You now have the complete system. Let's place a real order and trace it through every service.

### 10A — Test Unauthenticated Endpoints

```bash
# Get the product catalog (no auth required)
curl "https://<api-id>.execute-api.us-west-2.amazonaws.com/prod/products"
```

Expected: HTTP 200 with all 3 products (SHOES-001, SHIRT-001, JACKET-001).

### 10B — Test Auth Required on POST /order

```bash
# Try to place order without JWT (should fail)
curl -X POST \
  "https://<api-id>.execute-api.us-west-2.amazonaws.com/prod/order" \
  -H "Content-Type: application/json" \
  -d '{"productId": "SHOES-001", "quantity": 1}'
```

Expected: HTTP 401 `{"message": "Unauthorized"}` — the Cognito authorizer rejected the unauthenticated request.

### 10C — Place a Real Order

```bash
# Refresh JWT if it expired (tokens last 1 hour)
export JWT_TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id <YOUR_CLIENT_ID> \
  --auth-parameters USERNAME=testcustomer,PASSWORD="PermanentPass456!" \
  --region us-west-2 \
  --query 'AuthenticationResult.IdToken' \
  --output text)

# Place an order for shoes
curl -X POST \
  "https://<api-id>.execute-api.us-west-2.amazonaws.com/prod/order" \
  -H "Content-Type: application/json" \
  -H "Authorization: $JWT_TOKEN" \
  -d '{"productId": "SHOES-001", "quantity": 2}'
```

Expected: HTTP 202
```json
{"message": "Order received and processing", "orderId": "ORD-20260712123456-ABCD1234", "status": "PENDING", "total": 179.98}
```

Save the `orderId` value.

### 10D — Validate Each Service

**DynamoDB (initial state):**
1. DynamoDB > `AcmeOrders` > **Explore table items**.
2. Find your order. Status should be `PROCESSING` or `COMPLETED` (depending on how fast Step Functions ran).

**Step Functions:**
1. Step Functions > `AcmeOrderWorkflow` > **Executions**.
2. Find the execution named with your `orderId`.
3. Click it. The **Graph view** shows each state with green (succeeded) or red (failed) indicators.
4. Click on `ValidateOrder` → see the Lambda input/output.
5. Click on `CheckValidation` → see the choice result (validationStatus = PASSED).
6. Click on `NotifyAndFulfill` → see the Lambda output with `notificationSent: true`.
7. The execution should end at `OrderComplete` — all states green.

**SNS and Email:**
- Check your email. You should receive:
  - Subject: `Order ORD-... — PROCESSING`
  - Body with order details.

**SQS Fulfillment:**
1. SQS > `acme-fulfillment-queue` > **Send and receive messages** > **Poll for messages**.
2. If the `acme-fulfillment` Lambda processed the message already, the queue will be empty. That's correct behavior.

**Lambda Fulfillment Execution:**
1. Lambda > `acme-fulfillment` > **Monitor** > **View CloudWatch logs**.
2. Find the log stream for the recent invocation.
3. You should see: `Order ORD-... fulfilled.`

**DynamoDB (final state):**
1. DynamoDB > `AcmeOrders` > find your order again.
2. Status should now be `FULFILLED` (updated by the fulfillment Lambda).

**GET /order/{orderId}:**
```bash
curl "https://<api-id>.execute-api.us-west-2.amazonaws.com/prod/order/ORD-20260712123456-ABCD1234"
```
Expected: HTTP 200 with the order details including `"status": "FULFILLED"`.

### 10E — Test an Out-of-Stock Product

```bash
curl -X POST \
  "https://<api-id>.execute-api.us-west-2.amazonaws.com/prod/order" \
  -H "Content-Type: application/json" \
  -H "Authorization: $JWT_TOKEN" \
  -d '{"productId": "JACKET-001", "quantity": 1}'
```

JACKET-001 has `inventory: 0` and `status: OUT_OF_STOCK`.

Expected: The order is created (HTTP 202), but in Step Functions the `CheckValidation` Choice state routes to `OrderRejected` (not `ProcessOrder`). Check DynamoDB — the order status should be `REJECTED`.

### Full Trace Summary

```
Customer HTTP POST
    │ JWT validated by Cognito Authorizer
    ▼
API Gateway → acme-order-api Lambda
    │ Writes PENDING order to AcmeOrders
    │ Starts Step Functions execution
    ▼
Step Functions: AcmeOrderWorkflow
    │ → ValidateOrder Lambda: checks AcmeProducts inventory
    │ → CheckValidation Choice: PASSED → ProcessOrder
    │ → ProcessOrder: updates order to PROCESSING in DynamoDB
    │ → NotifyAndFulfill Lambda:
    │       → SNS Publish → email to ops team
    │       → SQS SendMessage → acme-fulfillment-queue
    │ → OrderComplete: updates order to COMPLETED in DynamoDB
    ▼
SQS → acme-fulfillment Lambda (event source mapping)
    │ → Updates order to FULFILLED in DynamoDB
    ▼
FINAL ORDER STATE: FULFILLED in DynamoDB
```

---

## Architecture Validation Checklist

- [ ] GET /products returns product catalog (no auth).
- [ ] POST /order without JWT returns 401.
- [ ] POST /order with JWT returns 202 with orderId.
- [ ] Step Functions execution completes all states (green).
- [ ] DynamoDB order shows final status FULFILLED.
- [ ] Email received from SNS.
- [ ] JACKET-001 order rejected (out of stock path works).
- [ ] CloudWatch dashboard shows invocation metrics.
- [ ] WAF Web ACL associated with API Gateway prod stage.
- [ ] No DLQ messages (fulfillment succeeded).

---

## Common Integration Mistakes

| Symptom | Root Cause | Fix |
|---|---|---|
| Lambda: `AccessDenied` on DynamoDB | IAM role missing permission or wrong ARN | Check inline policy ARN vs. actual table ARN |
| API returns 401 on all requests | Authorizer not attached to the method | Method Request > Authorization = CognitoJWT |
| Step Functions execution fails at `NotifyAndFulfill` | Lambda env vars (SNS_TOPIC_ARN/SQS_QUEUE_URL) not set | Set env vars on `acme-order-notifier` |
| SQS messages not processed | Event source mapping disabled or role missing SQS permissions | Lambda > Triggers, check enabled status |
| Step Functions: `States.TaskFailed` | Lambda threw an exception | Check CloudWatch logs for the specific Lambda |
| Order stuck in PENDING forever | `STATE_MACHINE_ARN` env var not set on `acme-order-api` | Update the env var with the actual ARN |
| SNS → SQS: messages not delivered | SQS access policy doesn't allow SNS | Add the `AllowSNSPublish` SQS policy statement |
| `acme-fulfillment` Lambda: key error | SQS message body is SNS-wrapped JSON | The fulfillment Lambda handles both wrapped and unwrapped — ensure code is deployed |

---

## Cost Summary for the Full System

| Service | Idle Monthly Cost | Per-Request Cost |
|---|---|---|
| DynamoDB (On-Demand) | $0 | $1.25/million reads, $1.25/million writes |
| Lambda (all 4 functions) | $0 | $0.20/million invocations + duration |
| API Gateway REST API | $0 | $3.50/million requests |
| Step Functions (Standard) | $0 | $0.025/1,000 state transitions |
| SNS | $0 | $0.50/million publishes |
| SQS | $0 | $0.40/million requests |
| Cognito | $0 (up to 50K MAU) | $0 for this lab |
| WAF | **~$5/month for Web ACL** | $0.60/million requests inspected |
| CloudWatch (dashboard) | **$3/month per dashboard** | — |
| **WAF + Dashboard total idle** | **~$8/month** | — |

> **Cost Awareness:** Most serverless services have zero idle cost — you only pay for what you use. The two exceptions in this lab are WAF (~$5/month) and the CloudWatch Dashboard ($3/month). **Delete these two specifically** as a priority. Everything else accumulates zero cost when idle.

---

## Challenge Exercises

### Challenge 1: Add EventBridge Daily Inventory Report

The Acme merchandise team wants a daily inventory summary delivered to their email every morning at 8 AM US Pacific Time (15:00 UTC). Create:
- An EventBridge scheduled rule (`cron(0 15 * * ? *)`) named `acme-daily-inventory`.
- A new Lambda function `acme-inventory-report` that:
  1. Scans the `AcmeProducts` table.
  2. Finds all products with `inventory < 10` (low stock).
  3. Publishes an SNS message to `acme-order-notify` with a formatted inventory report.
- The EventBridge rule targets `acme-inventory-report`.
- Test by triggering the rule manually and verifying the email.

**Requirements:**
- Create an appropriate IAM role for `acme-inventory-report` with least-privilege DynamoDB:Scan and SNS:Publish permissions.
- Show the complete Lambda code and EventBridge configuration.
- Explain how EventBridge passes information to the Lambda function in the `event` object.

### Challenge 2: Add X-Ray Tracing Across the Full Pipeline

The Acme engineering team wants distributed traces showing the full request journey from API Gateway through Lambda through Step Functions. Enable **AWS X-Ray** across the complete order processing path.

**Requirements:**
- Enable **Active tracing** on `acme-order-api` Lambda (X-Ray setting).
- Enable **Active tracing** on `acme-order-validator` and `acme-order-notifier` Lambda functions.
- Enable **X-Ray tracing** on the API Gateway `prod` stage.
- Enable **X-Ray tracing** on the `AcmeOrderWorkflow` Step Functions state machine.
- Add `aws_xray_sdk` annotations to the `acme-order-api` Lambda to add custom segments for the DynamoDB write and Step Functions start.
- Place a new order through the API and find the complete trace in X-Ray.
- Explain the trace: what is a **segment**, what is a **subsegment**, what is a **trace ID**, and how does X-Ray correlate segments across service boundaries?

**Hint:** Lambda functions need the `AWSXRayDaemonWriteAccess` IAM managed policy added to their execution roles. The X-Ray SDK for Python is `aws-xray-sdk`.

---

## Cleanup Instructions

Delete in reverse dependency order to avoid errors:

1. **WAF: Disassociate then delete Web ACL**
   - WAF > `acme-retail-web-acl` > Associated AWS resources > remove `prod` stage > Delete Web ACL.

2. **API Gateway: Delete the REST API**
   - API Gateway > `acme-retail-api` > Delete.

3. **Cognito: Delete User Pool**
   - Cognito > `AcmeRetailUsers` > Delete user pool.

4. **Step Functions: Delete State Machine**
   - Step Functions > `AcmeOrderWorkflow` > Delete. (Let in-flight executions complete first, or abort them.)

5. **Lambda: Delete all 4 functions**
   - Delete: `acme-order-api`, `acme-order-validator`, `acme-order-notifier`, `acme-fulfillment`.
   - Delete their CloudWatch log groups: CloudWatch > Log groups > `/aws/lambda/acme-order-*` > Delete.

6. **SNS: Delete subscriptions then topic**
   - SNS > Subscriptions > delete email subscription and SQS subscription.
   - SNS > Topics > `acme-order-notify` > Delete.

7. **SQS: Delete queues**
   - SQS > delete `acme-fulfillment-queue` (deletes DLQ association automatically).
   - SQS > delete `acme-fulfillment-dlq`.

8. **DynamoDB: Delete tables**
   - DynamoDB > `AcmeOrders` > Delete table.
   - DynamoDB > `AcmeProducts` > Delete table.

9. **CloudWatch: Delete dashboard and alarms**
   - CloudWatch > Dashboards > `AcmeRetailOps` > Delete.
   - CloudWatch > Alarms > delete `acme-order-api-errors` and `acme-fulfillment-dlq-messages`.
   - CloudWatch > Log groups > `/aws/states/AcmeOrderWorkflow` > Delete.

10. **IAM: Delete roles**
    - IAM > Roles > delete: `acme-order-api-role`, `acme-fulfillment-role`, `acme-step-functions-role`, `acme-validator-role`, `acme-notifier-role`.

---

## Key Takeaways

- A serverless architecture is a **composition of focused services** — each service does one job well. Lambda doesn't know about SQS; Step Functions doesn't know about DynamoDB directly — the roles and integrations are the glue.
- **IAM is the invisible security fabric** of the entire system. Every service boundary requires an explicit permission grant. Scoping to specific ARNs limits blast radius if any component is compromised.
- **Step Functions** decouples the "what needs to happen" (workflow) from the "how to do it" (Lambda functions). Adding a new step is a JSON change, not a code change.
- **SNS fan-out to SQS** gives you simultaneous multi-subscriber delivery with queue buffering — neither service alone provides both.
- **DynamoDB GSIs** are critical for query patterns beyond the primary key. Design your access patterns first, then your table and GSI structure.
- **WAF protects at the perimeter** — before any Lambda invocation. Blocking a SQLi probe at WAF costs fractions of a cent; letting it reach Lambda could trigger unexpected behavior and costs more.
- **Validate end-to-end, not just per-service.** Integration bugs (wrong ARNs, missing permissions, wrong event shapes) only appear when services actually talk to each other.
- The **idle cost** of this full system is approximately $8/month (WAF + CloudWatch dashboard). Every other service is pay-per-use with no idle charge.
