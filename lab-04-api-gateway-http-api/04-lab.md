# Lab 04: Building the Acme Retail Checkout API with Amazon API Gateway HTTP API

## Estimated Duration

~90 minutes

## Scenario / Business Context

**Acme Retail** is scaling its e-commerce platform. The engineering team has built several Lambda functions that handle product catalog lookups, order placement, and order status checks. Right now these functions live inside AWS Lambda and can only be called internally — the web team, mobile app, and third-party fulfillment partners have no way to reach them over HTTP.

Your mission is to build the **Acme Checkout API**: a public-facing HTTP API that exposes three endpoints:

| Route | Purpose |
|---|---|
| `GET /products` | Return a list of available products (optionally filtered by category) |
| `POST /order` | Accept a JSON order body and return a confirmation |
| `GET /order/{orderId}` | Return the status of a specific order |

You will learn how API Gateway HTTP APIs work, how the Lambda proxy integration contract functions, how to extract path parameters and query strings, how to enable access logging, and how to configure CORS so the Acme web storefront can call the API from a browser.

> **AWS Mental Model:** Think of API Gateway as the **front door, receptionist, and router** of your serverless backend. The internet knocks on the door (an HTTP request arrives), the receptionist reads the destination (route = method + path), and sends the visitor to the right room (your Lambda). Lambda does the work, hands a response back to the receptionist, who relays it to the client. Lambda never has to expose a socket to the internet — API Gateway handles all that.

```
Browser / curl / Mobile App
         |
         v
  [ API Gateway HTTP API ]   <-- public HTTPS endpoint
  ├── GET /products  ─────────> [ Lambda: acme-product-catalog ]
  ├── POST /order  ───────────> [ Lambda: acme-order-processor ]
  └── GET /order/{orderId} ──> [ Lambda: acme-order-status ]
```

## Learning Objectives

By the end of this lab you will be able to:

1. Explain the differences between HTTP APIs and REST APIs in API Gateway.
2. Create an HTTP API with multiple routes and Lambda integrations.
3. Describe the **payload format 2.0** event and expected response shape.
4. Extract **path parameters** (`{orderId}`) and **query string parameters** from a Lambda event.
5. Enable **access logging** to CloudWatch Logs for an HTTP API.
6. Configure **CORS** with origin-specific permissions.
7. Test API routes using the console test tool, `curl`, and a browser.
8. Explain the `$default` stage and auto-deploy behavior.
9. Understand **integration types**: Lambda proxy vs. HTTP proxy vs. mock.
10. Understand **throttling and rate limiting** defaults.

## AWS Services Used

- **Amazon API Gateway** (HTTP API)
- **AWS Lambda** (Python 3.12)
- **Amazon CloudWatch Logs**
- **AWS IAM** (execution roles, resource-based policies)

## Prerequisites

- An AWS account signed in as an **IAM user** (not root) with permissions for API Gateway, Lambda, CloudWatch Logs, and IAM.
- Region set to **US West (Oregon) `us-west-2`** throughout this lab.
- Familiarity with the Lambda console from Lab 03.

> **Common Beginner Mistake:** Accidentally working in the wrong region. Before every major step, glance at the top-right region selector and confirm it says **Oregon (us-west-2)**. AWS resources are region-scoped — an API in `us-east-1` won't see your Lambdas in `us-west-2`.

---

## Integration Type Reference

Before building, understand the three integration types you can choose in API Gateway HTTP APIs:

| Integration Type | What it does | When to use |
|---|---|---|
| **Lambda proxy** | Forwards the entire HTTP request as a structured JSON event to Lambda; Lambda returns the full HTTP response shape | Default choice for serverless backends — Lambda controls the full response |
| **HTTP proxy** | Forwards the request to an external HTTP URL (e.g., an ECS service, an existing REST API) | When you have a backend that already speaks HTTP and you want API Gateway as the front door |
| **Mock** | Returns a static response from API Gateway itself — no backend invoked | Useful for placeholder routes during development or for health-check endpoints that don't need Lambda |

> **AWS Mental Model:** The proxy integration means API Gateway is a **transparent pass-through** — it does not transform the request or response. Your Lambda sees the raw incoming HTTP details and you write the HTTP response yourself. This gives you maximum control and is the right default for Lambda backends.

---

## Part 1: Create the Lambda Functions

You need three Lambda functions. Work through all three before touching API Gateway.

### 1.1 Create the Product Catalog Lambda

1. Open the **Lambda console** at [https://us-west-2.console.aws.amazon.com/lambda](https://us-west-2.console.aws.amazon.com/lambda).
2. Confirm the region shows **Oregon (us-west-2)** in the top-right corner.
3. Click **Create function**.
4. Select **Author from scratch**.
5. Fill in:
   - **Function name:** `acme-product-catalog`
   - **Runtime:** `Python 3.12`
   - **Architecture:** `x86_64`
6. Under **Permissions**, leave **Create a new role with basic Lambda permissions** selected.
7. Click **Create function**.

Once created, click the **Code** tab, click `lambda_function.py` in the file explorer, replace all content with the following, then click **Deploy**:

```python
import json

# Simulated product catalog — in production this would query DynamoDB
PRODUCTS = [
    {"productId": "P001", "name": "Wireless Headphones", "price": 79.99, "category": "electronics", "inStock": True},
    {"productId": "P002", "name": "Running Shoes", "price": 129.99, "category": "footwear", "inStock": True},
    {"productId": "P003", "name": "Coffee Maker", "price": 49.99, "category": "kitchen", "inStock": False},
    {"productId": "P004", "name": "Yoga Mat", "price": 34.99, "category": "fitness", "inStock": True},
    {"productId": "P005", "name": "Bluetooth Speaker", "price": 59.99, "category": "electronics", "inStock": True},
]


def lambda_handler(event, context):
    # Extract optional 'category' query string parameter
    query_params = event.get("queryStringParameters") or {}
    category_filter = query_params.get("category", "").lower()

    if category_filter:
        results = [p for p in PRODUCTS if p["category"] == category_filter]
    else:
        results = PRODUCTS

    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
        },
        "body": json.dumps({
            "products": results,
            "count": len(results),
            "filteredBy": category_filter or None,
        }),
    }
```

> **What Is Happening Behind the Scenes?** The `event.get("queryStringParameters") or {}` pattern safely handles the case where no query parameters are passed — API Gateway sets this field to `None` when there are no query params, so the `or {}` prevents a `TypeError` on `.get("category")`.

**Validate Step 1.1:** Click **Test**, create a test event named `test-no-filter` with body `{}`, save and run. You should see `"statusCode": 200` and a list of all five products in the body. Then test with `{"queryStringParameters": {"category": "electronics"}}` as the event body — you should see only the two electronics products.

---

### 1.2 Create the Order Processor Lambda

1. Click **Functions** in the left nav, then **Create function**.
2. Fill in:
   - **Function name:** `acme-order-processor`
   - **Runtime:** `Python 3.12`
   - **Architecture:** `x86_64`
3. Leave default permissions, click **Create function**.

Replace the code and click **Deploy**:

```python
import json
import uuid
import time


def lambda_handler(event, context):
    # Parse JSON body — API Gateway sends the body as a string
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "Invalid JSON in request body"}),
        }

    # Basic validation
    required_fields = ["customerId", "items"]
    missing = [f for f in required_fields if f not in body]
    if missing:
        return {
            "statusCode": 422,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "error": "Missing required fields",
                "missingFields": missing,
            }),
        }

    items = body.get("items", [])
    if not items:
        return {
            "statusCode": 422,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "Order must contain at least one item"}),
        }

    # Generate order
    order_id = f"ORD-{uuid.uuid4().hex[:8].upper()}"
    total = sum(item.get("price", 0) * item.get("quantity", 1) for item in items)

    order_confirmation = {
        "orderId": order_id,
        "customerId": body["customerId"],
        "items": items,
        "totalAmount": round(total, 2),
        "currency": "USD",
        "status": "CONFIRMED",
        "estimatedDeliveryDays": 3,
        "createdAt": int(time.time()),
        "message": f"Thank you for your order! Your confirmation number is {order_id}.",
    }

    print(f"Order confirmed: {order_id} for customer {body['customerId']}, total ${total:.2f}")

    return {
        "statusCode": 201,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(order_confirmation),
    }
```

> **Why This Matters:** Notice the `statusCode: 201` (Created) — this is semantically correct HTTP for a resource-creation endpoint. API Gateway will forward exactly this status code to the client. Using meaningful HTTP status codes (200, 201, 400, 404, 422, 500) makes your API self-documenting and easier for client developers to handle.

**Validate Step 1.2:** Test with this event:
```json
{
  "body": "{\"customerId\": \"CUST-001\", \"items\": [{\"productId\": \"P001\", \"name\": \"Wireless Headphones\", \"price\": 79.99, \"quantity\": 1}]}"
}
```
Expect a `201` response with an `orderId` like `ORD-3A7F2C1B`.

---

### 1.3 Create the Order Status Lambda

1. Create another function named `acme-order-status`, runtime `Python 3.12`.
2. Replace code and deploy:

```python
import json

# Simulated order status store — in production this would be DynamoDB
FAKE_ORDERS = {
    "ORD-DEMO0001": {
        "orderId": "ORD-DEMO0001",
        "customerId": "CUST-001",
        "status": "SHIPPED",
        "carrier": "UPS",
        "trackingNumber": "1Z999AA10123456784",
        "estimatedDelivery": "2026-07-15",
    },
    "ORD-DEMO0002": {
        "orderId": "ORD-DEMO0002",
        "customerId": "CUST-002",
        "status": "PROCESSING",
        "carrier": None,
        "trackingNumber": None,
        "estimatedDelivery": None,
    },
}


def lambda_handler(event, context):
    # Extract path parameter — API Gateway injects these into pathParameters
    path_params = event.get("pathParameters") or {}
    order_id = path_params.get("orderId")

    if not order_id:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "orderId path parameter is required"}),
        }

    order = FAKE_ORDERS.get(order_id)
    if not order:
        return {
            "statusCode": 404,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "error": "Order not found",
                "orderId": order_id,
                "hint": "Try ORD-DEMO0001 or ORD-DEMO0002 for demo data",
            }),
        }

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(order),
    }
```

> **What Is Happening Behind the Scenes?** When API Gateway matches a route like `GET /order/{orderId}`, it extracts the `{orderId}` segment from the actual URL path and injects it into the Lambda event under `event["pathParameters"]["orderId"]`. Your Lambda never has to parse the raw URL string — API Gateway does that parsing for you and delivers a clean dictionary.

**Validate Step 1.3:** Test with:
```json
{
  "pathParameters": {"orderId": "ORD-DEMO0001"}
}
```
Expect a `200` with shipping info. Test with `{"pathParameters": {"orderId": "ORD-MISSING"}}` — expect a `404`.

---

## Part 2: Create the HTTP API

### 2.1 Open API Gateway

1. In the AWS Console search bar, type **API Gateway** and open the service.
2. Confirm **Oregon (us-west-2)** in the top-right.

### 2.2 Choose HTTP API

1. Click **Create API**.
2. On the API type selection screen, find the **HTTP API** option and click its **Build** button.

> **Common Beginner Mistake:** Clicking **Build** under **REST API** by mistake. REST API shows a completely different interface (Resources, Methods, Deployment stages, etc.). If your screens don't match, delete and restart with **HTTP API**.

> **HTTP API vs. REST API — Full Comparison:**
>
> | Feature | HTTP API | REST API |
> |---|---|---|
> | Cost | ~70% cheaper per request | Higher |
> | Latency | Lower (simpler processing) | Slightly higher |
> | JWT authorizers | Native, built-in | Requires Lambda authorizer |
> | Request/response transforms | Not available | Available (mapping templates) |
> | API keys and usage plans | Not available | Available |
> | AWS WAF integration | Not available | Available |
> | Private APIs | Not available | Available |
> | Mock integrations | Available | Available |
> | Recommended for | Lambda + HTTP backends | Advanced features, legacy |

### 2.3 Add the first integration

On the **Create an API** screen:

1. Under **Integrations**, click **Add integration**.
2. Choose **Lambda**.
3. **AWS Region:** `us-west-2`.
4. **Lambda function:** type `acme-product-catalog` and select it.
5. **Payload format version:** leave at **2.0** (this is correct and default for HTTP APIs).
6. Leave the integration name as auto-generated.

Add a second integration:
7. Click **Add integration** again.
8. Choose **Lambda**, region `us-west-2`, function `acme-order-processor`.

Add a third integration:
9. Click **Add integration** again.
10. Choose **Lambda**, region `us-west-2`, function `acme-order-status`.

11. **API name:** `acme-checkout-api`.
12. Click **Next**.

---

### 2.4 Configure Routes

On the **Configure routes** screen, set up all three routes:

**Route 1:**
- **Method:** `GET`
- **Resource path:** `/products`
- **Integration target:** `acme-product-catalog`

Click **Add route** to add the next:

**Route 2:**
- **Method:** `POST`
- **Resource path:** `/order`
- **Integration target:** `acme-order-processor`

Click **Add route** again:

**Route 3:**
- **Method:** `GET`
- **Resource path:** `/order/{orderId}`
- **Integration target:** `acme-order-status`

> **What Is Happening Behind the Scenes? — `{orderId}` Path Parameter:** The curly braces tell API Gateway this segment of the path is a **variable**. Any request matching `GET /order/ANYTHING` will match this route, and the captured value will be injected into `event["pathParameters"]["orderId"]` in your Lambda. This is how RESTful APIs express resource-specific endpoints.

Click **Next**.

---

### 2.5 Configure the Stage

On the **Define stages** screen:

- You will see stage **`$default`** with **Auto-deploy: On**.
- Leave this exactly as-is. Click **Next**.

> **Routes vs. Stages Mental Model:**
> - A **route** describes *what* your API can do — the available methods and paths.
> - A **stage** is a *deployed snapshot* of your API — `dev`, `staging`, `prod` — each with its own Invoke URL.
> - The `$default` stage is special: it has no stage prefix in the URL and with **auto-deploy on**, every change you make is live immediately — no separate "Deploy" button needed.

### 2.6 Review and Create

1. Review: API name `acme-checkout-api`, 3 integrations, 3 routes, stage `$default`.
2. Click **Create**.

**Validation:** You are taken to the API overview page. In the left nav, click **Stages → $default**. Copy the **Invoke URL** — it looks like:
```
https://abc1234xyz.execute-api.us-west-2.amazonaws.com
```
Save this URL — you will use it throughout the lab.

---

## Part 3: Understand Payload Format 2.0

Before testing, fully understand the contract between API Gateway and your Lambda functions.

### 3.1 The Event Your Lambda Receives

When API Gateway invokes your Lambda with **payload format 2.0**, the event looks like this (abbreviated):

```json
{
  "version": "2.0",
  "routeKey": "GET /products",
  "rawPath": "/products",
  "rawQueryString": "category=electronics",
  "headers": {
    "host": "abc1234xyz.execute-api.us-west-2.amazonaws.com",
    "content-type": "application/json",
    "user-agent": "curl/7.88.1"
  },
  "queryStringParameters": {
    "category": "electronics"
  },
  "pathParameters": {},
  "requestContext": {
    "accountId": "123456789012",
    "apiId": "abc1234xyz",
    "http": {
      "method": "GET",
      "path": "/products",
      "protocol": "HTTP/1.1",
      "sourceIp": "203.0.113.42",
      "userAgent": "curl/7.88.1"
    },
    "requestId": "Yh1AbCD2=",
    "routeKey": "GET /products",
    "stage": "$default",
    "time": "12/Jul/2026:14:23:01 +0000",
    "timeEpoch": 1752327781000
  },
  "body": null,
  "isBase64Encoded": false
}
```

For a `POST /order` request with a JSON body:
- `event["body"]` will be a **JSON string** (not a dict) — you must call `json.loads(event["body"])` to parse it.
- `event["headers"]["content-type"]` will be `application/json`.

For a `GET /order/{orderId}` request to `/order/ORD-DEMO0001`:
- `event["pathParameters"]["orderId"]` = `"ORD-DEMO0001"`

### 3.2 The Response Your Lambda Must Return

```python
{
    "statusCode": 200,          # Required: integer HTTP status code
    "headers": {                # Optional: dict of response headers
        "Content-Type": "application/json",
        "X-Request-Id": "abc-123"
    },
    "body": "..."               # Required: MUST be a string — JSON.dumps() if sending JSON
    "isBase64Encoded": False    # Optional: True only for binary payloads
}
```

> **Common Beginner Mistake:** Returning a Python dict as `body` instead of a string:
> ```python
> # WRONG — body must be a string, not a dict
> return {"statusCode": 200, "body": {"message": "ok"}}
>
> # CORRECT
> return {"statusCode": 200, "body": json.dumps({"message": "ok"})}
> ```
> If you return the wrong shape, API Gateway responds with `502 Bad Gateway` and the body will be `{"message": "Internal Server Error"}`. Always `json.dumps()` your response body.

---

## Part 4: Enable Access Logging to CloudWatch

Access logs record every HTTP request to your API — who called it, what route, what status code was returned, and how long it took. This is essential for debugging and monitoring in production.

### 4.1 Create a CloudWatch Log Group for API Access Logs

1. Open **CloudWatch** in a new browser tab (search bar → CloudWatch).
2. In the left nav, click **Logs → Log groups**.
3. Click **Create log group**.
4. **Log group name:** `/aws/apigateway/acme-checkout-api/access-logs`
5. **Retention setting:** `7 days` (no reason to keep test logs indefinitely).
6. Click **Create**.
7. Click on the new log group and copy its **ARN** from the detail header — it looks like:
   ```
   arn:aws:logs:us-west-2:123456789012:log-group:/aws/apigateway/acme-checkout-api/access-logs
   ```

### 4.2 Enable Access Logging on the `$default` Stage

1. Return to the **API Gateway** tab.
2. In the left nav, select your API **acme-checkout-api**.
3. Click **Stages** → **$default**.
4. Click **Edit** (top right of the stage detail panel).
5. Find **Access logging** and enable it.
6. **CloudWatch Logs ARN:** paste the ARN you copied from CloudWatch.
7. **Log format:** select **JSON** (structured logs are far easier to query). The default JSON format string includes request ID, IP, status, and latency.
8. Click **Save**.

> **What Is Happening Behind the Scenes?** API Gateway needs permission to write to your CloudWatch log group. This permission is granted via an **account-level** IAM role for API Gateway (separate from your Lambda execution roles). If you get an error like "CloudWatch Logs role ARN must be set in account settings," you need to configure an API Gateway CloudWatch role for your account under **API Gateway → Settings**. If prompted, create the role with the managed policy `AmazonAPIGatewayPushToCloudWatchLogs` and set its ARN in the account settings.

**Validate Step 4:** Make a test call to your API (any route). Then go to **CloudWatch → Log groups → `/aws/apigateway/acme-checkout-api/access-logs`**. Within 30 seconds, you should see a log stream with a JSON entry for your request, including the `status`, `requestId`, `ip`, and `responseLength` fields.

---

## Part 5: Configure CORS

CORS (Cross-Origin Resource Sharing) is a **browser security mechanism** that blocks web pages from making HTTP requests to a different domain than the one that served the page. If Acme's storefront at `https://shop.acme.com` tries to call `https://abc1234xyz.execute-api.us-west-2.amazonaws.com`, the browser will block it — unless the API explicitly allows it with CORS headers.

> **Why This Matters:** `curl`, Postman, and server-to-server calls are NOT subject to CORS — it only applies to browser-based JavaScript (XMLHttpRequest, fetch). This is why your API "works in Postman but not the web app."

### 5.1 Configure CORS on the API

1. In the **API Gateway** left nav, click **CORS**.
2. Click **Configure**.
3. Set:
   - **Access-Control-Allow-Origin:** `http://localhost:3000` (for local dev). In production you would list each allowed origin — e.g., `https://shop.acme.com`. You can also use `*` for a fully public API.
   - **Access-Control-Allow-Methods:** `GET, POST, OPTIONS`
   - **Access-Control-Allow-Headers:** `content-type, authorization`
   - **Access-Control-Max-Age:** `300` (seconds the browser can cache the preflight response)
4. Click **Save**.

> **Security Consideration:** `Access-Control-Allow-Origin: *` permits JavaScript from any website to call your API. For authenticated endpoints (routes that require tokens), never use `*` — always list specific origins. For truly public read-only endpoints (like `GET /products`), `*` is acceptable.

---

## Part 6: Test the API

### 6.1 Test GET /products in the browser

1. Take your Invoke URL and append `/products`:
   ```
   https://abc1234xyz.execute-api.us-west-2.amazonaws.com/products
   ```
2. Paste it in a browser. Expected result — JSON with all five products:
   ```json
   {"products": [...], "count": 5, "filteredBy": null}
   ```

### 6.2 Test GET /products with category filter

Add a query string:
```
https://abc1234xyz.execute-api.us-west-2.amazonaws.com/products?category=electronics
```
Expected: only the 2 electronics products returned.

### 6.3 Test GET /products with curl

```bash
# Get all products
curl -s https://abc1234xyz.execute-api.us-west-2.amazonaws.com/products | python3 -m json.tool

# Filter by category
curl -s "https://abc1234xyz.execute-api.us-west-2.amazonaws.com/products?category=fitness" | python3 -m json.tool
```

### 6.4 Test POST /order with curl

```bash
curl -s -X POST \
  https://abc1234xyz.execute-api.us-west-2.amazonaws.com/order \
  -H "Content-Type: application/json" \
  -d '{
    "customerId": "CUST-001",
    "items": [
      {"productId": "P001", "name": "Wireless Headphones", "price": 79.99, "quantity": 1},
      {"productId": "P004", "name": "Yoga Mat", "price": 34.99, "quantity": 2}
    ]
  }' | python3 -m json.tool
```

Expected response (HTTP 201):
```json
{
  "orderId": "ORD-3A7F2C1B",
  "customerId": "CUST-001",
  "totalAmount": 149.97,
  "status": "CONFIRMED",
  "message": "Thank you for your order! Your confirmation number is ORD-3A7F2C1B."
}
```

**Test a 422 error** by submitting an incomplete body:
```bash
curl -s -X POST \
  https://abc1234xyz.execute-api.us-west-2.amazonaws.com/order \
  -H "Content-Type: application/json" \
  -d '{"customerId": "CUST-001"}' | python3 -m json.tool
```
Expected: `422` with `"missingFields": ["items"]`.

### 6.5 Test GET /order/{orderId}

```bash
# Valid demo order
curl -s https://abc1234xyz.execute-api.us-west-2.amazonaws.com/order/ORD-DEMO0001 | python3 -m json.tool

# Non-existent order
curl -s https://abc1234xyz.execute-api.us-west-2.amazonaws.com/order/ORD-MISSING | python3 -m json.tool
```

Expected: `200` with tracking info for `ORD-DEMO0001`; `404` with an error for `ORD-MISSING`.

### 6.6 Test Using the Console Test Tool

The console has a built-in test tool:

1. In API Gateway, left nav → **Routes**.
2. Click **GET /products**.
3. Click **Test** in the route detail panel.
4. In the test pane that appears, you can add query string parameters (e.g. key `category`, value `kitchen`) and click **Send**.
5. The response panel shows the status code, headers, and body — all without leaving the console.

> **Why This Matters:** The console test tool is extremely useful for debugging routing issues because it shows you exactly what API Gateway sees before and after the integration call. If your Lambda is misconfigured, you'll see the raw error response here.

---

## Part 7: Throttling, Rate Limiting, and Stage Variables

### 7.1 Default Throttling Limits

API Gateway HTTP APIs apply throttling to protect your backend from traffic spikes:

| Limit | Default Value |
|---|---|
| Account-level burst limit | 5,000 requests/second |
| Account-level rate limit | 10,000 requests/second |
| Per-route throttling | Configurable per route on a stage |

When a client exceeds the limit, API Gateway returns `429 Too Many Requests` before the request reaches your Lambda — your Lambda is never invoked, and you are not billed for a Lambda invocation.

> **What Is Happening Behind the Scenes?** Throttling is applied at the API Gateway layer, before your Lambda is called. This protects your Lambda from cold starts and concurrency limits under unexpected traffic surges. For production APIs serving large scale, you should also configure **per-route throttling** (available under **Stages → $default → Edit → Route throttling**) to give more budget to critical routes like `POST /order` and less to read endpoints.

### 7.2 Stage Variables

Stage variables are key-value pairs stored on a stage that can be referenced in integration configurations. They let you point the same API route at different Lambda functions (or ARNs) depending on which stage is being called:

- `dev` stage: `acme-order-processor` function alias pointing to dev code.
- `prod` stage: `acme-order-processor` function alias pointing to production code.

Stage variables are accessed in integration configs using `${stageVariables.variableName}` syntax. HTTP API stage variables are supported for HTTP integrations but have limited support for Lambda integrations (you typically use Lambda aliases/versions directly). Understanding the concept is the key takeaway here.

---

## Part 8: Custom Domain Names (Concept Only)

In production, Acme won't expose the auto-generated URL `abc1234xyz.execute-api.us-west-2.amazonaws.com` to customers. They'll use `api.acme.com`.

**How it works (concept):**
1. In **ACM (AWS Certificate Manager)**, request a public certificate for `api.acme.com` in `us-east-1` (required for edge-optimized) or your API's region.
2. In API Gateway → **Custom domain names**, create a custom domain `api.acme.com` and attach the certificate.
3. Create an **API mapping** to map `api.acme.com/v1` → your `acme-checkout-api` `$default` stage.
4. In your DNS provider (Route 53 or external), create a CNAME record pointing `api.acme.com` to the API Gateway target domain name.

> **Why we don't configure this in the lab:** Custom domain setup requires a registered domain, DNS propagation time (up to 48 hours), and ACM certificate validation. The concepts are important to understand; the mechanics are straightforward once you own a domain.

---

## Key Takeaways

- **HTTP API vs. REST API:** HTTP API is cheaper, faster, and has built-in JWT authorizers. REST API adds request/response transforms, API keys, WAF, and private endpoints. Default to HTTP API unless you need REST features.
- **Routes = method + path** (`GET /products`). Use `{paramName}` for path variables. Parameters are injected into `event["pathParameters"]`.
- **The `$default` stage with auto-deploy** means changes go live instantly — no separate deploy step.
- **Payload format 2.0:** Lambda receives a structured event; must return `{ "statusCode", "headers", "body" }` where `body` is always a **string**.
- **Query strings** are in `event["queryStringParameters"]` — always treat this as potentially `None`.
- **CORS** is a browser rule only; `curl` bypasses it. Restrict `Allow-Origin` to specific domains in production.
- **Access logs** to CloudWatch are essential for production debugging.
- **Throttling (429)** happens at the API layer before Lambda is invoked, protecting your backend.

---

## Challenge Exercises

Work through these on your own. Solutions are in `04-solutions.md`.

### Challenge 1: Add a POST /review Route

Acme wants customers to submit product reviews. Add a new route to your existing API:

**Route:** `POST /review`

**Required request body fields:**
- `productId` (string)
- `customerId` (string)
- `rating` (integer, 1–5)
- `reviewText` (string)

**Requirements:**
1. Create a new Lambda function named `acme-review-processor` (Python 3.12).
2. The Lambda must validate that `rating` is an integer between 1 and 5 — return `422` if not.
3. If valid, return a `201` response with a generated `reviewId` (e.g., `REV-XXXXXXXX`), the submitted data, and a `"status": "PENDING_MODERATION"` field.
4. Add the route `POST /review` to your existing `acme-checkout-api` API.
5. Test with curl.

**Hint:** Adding a new route to an existing HTTP API: go to API Gateway → your API → Routes → Create.

---

### Challenge 2: Add Query String Filtering to GET /products

Your existing `GET /products` route already supports `?category=electronics`. Extend it further:

**New query string parameters to support:**
- `?inStock=true` — return only in-stock products
- `?maxPrice=60` — return only products with `price <= maxPrice`
- `?sort=price_asc` or `?sort=price_desc` — sort results by price

**Requirements:**
1. Update the `acme-product-catalog` Lambda to handle all three new parameters.
2. The parameters should be **combinable** (e.g., `?category=electronics&inStock=true&maxPrice=80`).
3. Return a `400` if `maxPrice` is provided but is not a valid number.
4. Test all combinations with curl.

---

## Cleanup Instructions

Delete in this order to avoid dependency errors:

### 1. Delete the HTTP API

1. Go to **API Gateway → APIs**.
2. Select **`acme-checkout-api`** → **Actions → Delete** → confirm.

### 2. Delete the Lambda Functions

1. Go to **Lambda → Functions**.
2. Select `acme-product-catalog` → **Actions → Delete** → confirm.
3. Repeat for `acme-order-processor` and `acme-order-status`.
4. If you created `acme-review-processor` for Challenge 1, delete it too.

### 3. Delete the CloudWatch Log Group

1. Go to **CloudWatch → Log groups**.
2. Select `/aws/apigateway/acme-checkout-api/access-logs` → **Actions → Delete log group** → confirm.
3. Lambda auto-creates log groups like `/aws/lambda/acme-product-catalog` — delete those too.

> **Cost Awareness:** API Gateway charges per request. An idle API with no traffic incurs no charges. CloudWatch Logs storage accrues a small charge per GB per month. Lambda has a generous free tier. Still, clean up any resources you no longer need — the habit of deleting test infrastructure is one of the most valuable cost-control practices to build early.
