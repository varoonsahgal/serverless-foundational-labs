# Exercise 04: Expose a Lambda Function Through an Amazon API Gateway HTTP API

## Estimated Duration

~40 minutes

## Scenario / Business Context

**Acme Retail** has a small backend function that can greet customers and (later) process orders. Right now that function lives inside AWS Lambda and can only be triggered from the AWS Console or the AWS Command Line Interface (CLI). The Acme web and mobile teams need a real, public web address (a URL) they can call over the internet using standard HTTP.

Your job as a new Acme cloud engineer is to put a **front door** in front of the Lambda function using **Amazon API Gateway** so that a browser, a mobile app, or a `curl` command can reach it. You will build an **HTTP API**, wire it to the Lambda function, add a route, enable browser access (CORS), and validate that a real HTTP request returns a real HTTP response.

## Learning Objectives

By the end of this exercise, you will be able to:

- Explain what Amazon API Gateway does and where it sits in a serverless architecture.
- Create an **HTTP API** (not a REST API) and attach a Lambda integration.
- Define a **route** (method + path) and understand the difference between routes and stages.
- Explain the automatic `$default` stage, auto-deploy, and the Invoke URL.
- Describe the Lambda **proxy integration** event/response format (payload format version 2.0).
- Enable and reason about **CORS** (Cross-Origin Resource Sharing).
- Validate the API from a browser and with `curl`.

## AWS Services Used

- **Amazon API Gateway** (HTTP API)
- **AWS Lambda**
- **Amazon CloudWatch Logs** (created automatically by Lambda)
- **AWS Identity and Access Management (IAM)** (execution role for Lambda)

## Prerequisites

- An AWS account.
- An **IAM user** with permissions for API Gateway and Lambda. **Do not use the root user** — sign in as an IAM user (or an IAM Identity Center user) with administrative or equivalent permissions.
- Region set to **US East (N. Virginia) `us-east-1`** in the top-right region selector of the console.
- **A working Lambda function.**
  - If you completed **Exercise 03**, you can reuse your existing `acme-order-processor` function.
  - If you did **not** do Exercise 03, this lab is fully self-contained: **Step 1 below** guides you to create a minimal Lambda named `acme-hello`. Do that first.

> **Note:** Throughout this lab, wherever you see `acme-hello`, substitute `acme-order-processor` if you are reusing your Exercise 03 function. The steps are identical; only the function name and route path differ.

---

## Step 1: Create (or Reuse) the Lambda Function

**Skip this step if you are reusing `acme-order-processor`.** Jump to Step 2 and select that function instead.

### 1.1 Open the Lambda console

1. In the AWS Console search bar (top of the screen), type **Lambda** and click the **Lambda** service.
2. Confirm the region in the top-right says **N. Virginia (us-east-1)**.
3. Click the orange **Create function** button.

### 1.2 Configure the function

- **Author from scratch** (leave selected).
- **Function name:** `acme-hello`
- **Runtime:** **Python 3.12**
- **Architecture:** `x86_64` (default).
- Leave **Permissions** at the default: *Create a new role with basic Lambda permissions*. This automatically creates an IAM execution role so the function can write logs to CloudWatch.
- Click **Create function**.

**What each setting does:** The *runtime* tells Lambda which language interpreter to run. The *execution role* is the identity your function runs as — it grants the function permission to write log output. Basic permissions are all we need here.

### 1.3 Add the function code

1. Scroll down to the **Code source** panel. You will see a file named `lambda_function.py`.
2. Replace its entire contents with the following code, then click **Deploy** (or press `Ctrl+S` / `Cmd+S`):

```python
import json


def lambda_handler(event, context):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "text/plain"},
        "body": "Hello from Acme"
    }
```

3. Wait for the green **Changes deployed** banner.

> **What Is Happening Behind the Scenes?** This response shape — a dictionary with `statusCode`, optional `headers`, and `body` — is exactly what API Gateway's **proxy integration** expects to receive back. API Gateway reads those fields and turns them into a real HTTP response. We will explain this in detail in Step 4.

**Validation for Step 1:** In the Lambda console, click **Test**, create a test event named `test` (accept the default `{}` JSON), click **Save**, then click **Test** again. You should see `"statusCode": 200` and `"body": "Hello from Acme"` in the execution result. The function works — now let's put a front door on it.

---

## Step 2: Create the HTTP API

### 2.1 Open API Gateway

1. In the AWS Console search bar, type **API Gateway** and click the **API Gateway** service.
2. Confirm the region is **us-east-1**.

### 2.2 Choose HTTP API (not REST API)

1. On the API Gateway landing page you will see several API types: **HTTP API**, **WebSocket API**, and **REST API**.
2. Find the **HTTP API** box and click its **Build** button.

> **Common Beginner Mistake:** Clicking **Build** under **REST API** by accident. REST API has a completely different set of screens (Resources, Methods, Deploy API, etc.). If your screens don't match this lab, you probably created the wrong type. Delete it and start again with **HTTP API**.

> **HTTP API vs. REST API:** **HTTP APIs** are the newer, simpler, lower-cost option — ideal for straightforward Lambda and HTTP backends. **REST APIs** are older and add advanced features (request/response transformation, API keys and usage plans, AWS WAF integration, private APIs, edge-optimized endpoints, fine-grained request validation). For most serverless apps, HTTP API is the right default. This lab uses HTTP API.

### 2.3 Add the integration

On the **Create an API** screen:

1. Under **Integrations**, click **Add integration**.
2. Choose **Lambda** from the dropdown.
3. **AWS Region:** `us-east-1`.
4. **Lambda function:** start typing `acme-hello` (or `acme-order-processor`) and select it. You can paste the full function name or its ARN.
5. **Version:** leave **2.0** selected for **Payload format version** if shown. (2.0 is the default and correct choice for HTTP APIs.)
6. **API name:** `acme-http-api`
7. Click **Next**.

> **AWS Mental Model:** Think of API Gateway as the **front door and receptionist** of your application. The internet knocks on the door (an HTTP request arrives), the receptionist looks at *which door* was used (the route — method + path), and routes the visitor to the correct room (your Lambda). Lambda does the work and hands back a response, which the receptionist delivers to the visitor. Lambda never has to deal with the public internet directly.

---

## Step 3: Configure the Route

### 3.1 Define the route

On the **Configure routes** screen you'll see one route pre-filled from your integration. Set it as follows:

- **Method:** `GET`
- **Resource path:** `/hello`
  - (If you are reusing `acme-order-processor`, you may prefer `/order` — either is fine for this step. This lab uses `/hello`.)
- **Integration target:** `acme-hello` (already selected).

Click **Next**.

> **Routes vs. Stages:** A **route** is *what* a client asks for — a combination of an HTTP method (`GET`, `POST`, etc.) and a path (`/hello`). A **stage** is *which deployed copy* of the API is being called — for example a `dev` stage vs. a `prod` stage, each with its own URL. Routes describe the API's shape; stages describe deployed environments of that shape.

### 3.2 Review the stage

On the **Define stages** screen:

- You will see a stage named **`$default`** with **Auto-deploy** turned **on**.
- Leave this as-is. Click **Next**.

> **What Is Happening Behind the Scenes?** The **`$default` stage** is a special automatic stage. With **auto-deploy** enabled, any change you make to routes or integrations is deployed **immediately** — you never have to click a separate "Deploy" button (unlike REST APIs, which require manual deployments). The `$default` stage does not add a stage name to your URL, so your Invoke URL stays clean.

### 3.3 Create the API

1. On the **Review and create** screen, confirm: API name `acme-http-api`, one integration to `acme-hello`, one route `GET /hello`, one stage `$default`.
2. Click **Create**.

**Validation for Step 3:** You are taken to the API's detail page. In the left menu, click **Stages** and select **`$default`**. Copy the **Invoke URL** — it looks like:

```
https://abc123xyz.execute-api.us-east-1.amazonaws.com
```

> **What is an Invoke URL?** It's the public base web address AWS generated for your API's stage. The random subdomain (`abc123xyz`) is your unique API ID. To actually call a route, you append the route's path — e.g. `https://abc123xyz.execute-api.us-east-1.amazonaws.com/hello`.

---

## Step 4: Understand the Proxy Integration (Payload Format 2.0)

Before testing, understand the contract between API Gateway and your Lambda.

**The request (event) your Lambda receives.** With **payload format version 2.0**, API Gateway invokes your Lambda with a JSON event that looks roughly like this (trimmed):

```json
{
  "version": "2.0",
  "routeKey": "GET /hello",
  "rawPath": "/hello",
  "headers": { "host": "abc123xyz.execute-api.us-east-1.amazonaws.com" },
  "queryStringParameters": { "name": "Ada" },
  "requestContext": {
    "http": { "method": "GET", "path": "/hello" }
  },
  "body": null,
  "isBase64Encoded": false
}
```

Your function can read `event["queryStringParameters"]`, `event["body"]`, `event["requestContext"]["http"]["method"]`, etc.

**The response your Lambda must return.** For a proxy integration, your Lambda must return an object shaped like this:

```python
{
    "statusCode": 200,
    "headers": {"Content-Type": "text/plain"},
    "body": "Hello from Acme"
}
```

- `statusCode` (required): the HTTP status code API Gateway will send back (e.g., 200, 404, 500).
- `headers` (optional): HTTP response headers.
- `body` (required): a **string**. If you're returning JSON, use `json.dumps(...)` to serialize it to a string.
- `isBase64Encoded` (optional): set `true` only for binary responses.

> **Common Beginner Mistake:** Returning a raw Python dict as the *body* (e.g. `"body": {"msg": "hi"}`) or returning the value directly without a `statusCode`. With proxy integration, the `body` must be a **string** and the top-level object must include `statusCode`. If you return the wrong shape, API Gateway responds with `500 Internal Server Error` and a message like *"Internal Server Error"*. Our `acme-hello` function already returns the correct shape.

> **Assessment Connection:** Understanding the difference between the raw Lambda return value and the HTTP response the client sees (the proxy contract) is a frequently assessed serverless concept. Be able to explain: *"API Gateway maps the `statusCode`, `headers`, and `body` fields of my Lambda's return value onto the HTTP response."*

---

## Step 5: Enable CORS (Cross-Origin Resource Sharing)

**CORS = Cross-Origin Resource Sharing.** It is a browser security feature. If JavaScript running on `https://shop.acme.com` tries to call your API at `https://abc123xyz.execute-api.us-east-1.amazonaws.com`, the browser considers that a **cross-origin** request and will **block** it unless the API explicitly says "I allow that origin." (Note: `curl` and server-to-server calls are *not* subject to CORS — this is purely a browser protection.)

### 5.1 Configure CORS on the HTTP API

1. In your API's left menu, click **CORS**.
2. Click **Configure** (or **Add**).
3. Set the following:
   - **Access-Control-Allow-Origin:** for testing, enter a specific origin such as `http://localhost:3000` (a common local dev address) **or** `*` to allow any origin.
   - **Access-Control-Allow-Methods:** add `GET` (and `POST` if you'll do the challenge).
   - **Access-Control-Allow-Headers:** add `content-type`.
4. Click **Save**.

> **Security Consideration:** `Access-Control-Allow-Origin: *` means *any* website's JavaScript can call your API from a browser. That's convenient for a lab but risky for anything real. In production, list the **specific** origin(s) your frontend is served from (e.g., `https://shop.acme.com`). Use `*` only when the endpoint is genuinely public and unauthenticated.

> **Why This Matters:** A huge fraction of "my API works in curl/Postman but not in my web app" support tickets are CORS problems. Knowing that CORS is a *browser* rule enforced via response headers — not a firewall — saves hours of confusion.

---

## Step 6: Validate the API

### 6.1 Test in a browser

1. Take your Invoke URL and append the route path:
   ```
   https://abc123xyz.execute-api.us-east-1.amazonaws.com/hello
   ```
2. Paste it into a browser tab and press Enter.
3. **Expected result:** the page shows `Hello from Acme`.

> **Common Beginner Mistake:** Opening the base Invoke URL **without** the `/hello` path. That returns `{"message":"Not Found"}` because no route matches `/`. Always append your route path.

### 6.2 Test with curl

Open a terminal and run (replace the host with your own Invoke URL):

```bash
curl -i https://abc123xyz.execute-api.us-east-1.amazonaws.com/hello
```

**Expected result:**

```
HTTP/2 200
content-type: text/plain
...

Hello from Acme
```

The `-i` flag includes the response headers so you can see the `HTTP/2 200` status line and confirm the status code came from your Lambda's `statusCode` field.

> **What Is Happening Behind the Scenes?** When you created the integration, API Gateway automatically added a **resource-based permission** (a `lambda:InvokeFunction` permission statement) to your Lambda function that allows this specific API to invoke it. You did not have to configure any IAM policy by hand. You can see it in the Lambda console under **Configuration → Permissions → Resource-based policy statements**. Without this permission, API Gateway calls would fail with `500` / access denied.

---

## Concept Callouts Summary

> **AWS Mental Model:** API Gateway = the front door / router. It accepts internet traffic, matches it to a route, and forwards it to a backend (Lambda). Your backend stays private and just does its job.

> **Cost Awareness:** HTTP APIs are billed **per request** (plus data transfer). There is no hourly charge for an idle API, but the safest way to guarantee zero cost is to **delete the API** when you're done. The AWS Free Tier includes a monthly allotment of API Gateway HTTP API requests for the first 12 months. A handful of test requests costs effectively nothing, but always clean up.

---

## Key Takeaways

- **API Gateway is the front door** to serverless backends; it exposes private Lambdas over HTTP.
- Use an **HTTP API** for simple, low-cost Lambda/HTTP backends; use REST API only when you need its advanced features.
- A **route** = method + path (`GET /hello`); a **stage** = a deployed environment. The `$default` stage with auto-deploy means changes go live instantly and the URL stays clean.
- The **Invoke URL** is the base address; you must **append the route path** to call a route.
- **Proxy integration (payload format 2.0):** Lambda receives a structured `event` and must return `{ "statusCode", "headers", "body" }` where `body` is a **string**.
- **CORS** is a browser rule; enable it (with a specific origin when possible) so web frontends can call your API. `curl` bypasses CORS.
- API Gateway **auto-adds a resource-based permission** to let the API invoke your Lambda.

---

## Cleanup Instructions

Delete everything you created so nothing lingers or accrues cost.

### Delete the HTTP API

1. Go to **API Gateway → APIs**.
2. Select **`acme-http-api`**.
3. Click **Actions → Delete** (or the **Delete** button), type the confirmation, and confirm.

### Delete the helper Lambda (only if you created `acme-hello` for this lab)

> Skip this if you reused `acme-order-processor` and still need it.

1. Go to **Lambda → Functions**.
2. Select **`acme-hello`** → **Actions → Delete** → confirm.

### Delete the CloudWatch log group

1. Go to **CloudWatch → Log groups**.
2. Find **`/aws/lambda/acme-hello`**, select it, and choose **Actions → Delete log group(s)** → confirm.

### Delete the IAM execution role (optional)

1. Go to **IAM → Roles**.
2. Search for the auto-created role (named like `acme-hello-role-xxxxxx`).
3. Select it and choose **Delete** → confirm.

> **Cost Awareness:** None of these resources cost anything while idle, but deleting them keeps your account tidy and eliminates any per-request charges.

---

## Early-Finisher Challenge

Add a **second route: `POST /order`** integrated with the **same** Lambda function, then test it with `curl` by sending a JSON body. Confirm you get a `200` response.

Try it yourself before reading the solution.

---

## Challenge Solution

### Step A: Update the Lambda to echo the posted body (optional but recommended)

So you can *see* the request body come through, update `acme-hello`'s code to read the incoming body and return it. In the Lambda console, replace the code with:

```python
import json


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    raw_body = event.get("body")

    if method == "POST" and raw_body:
        try:
            data = json.loads(raw_body)
        except json.JSONDecodeError:
            data = {"raw": raw_body}
        response_body = json.dumps({"message": "Order received", "order": data})
    else:
        response_body = json.dumps({"message": "Hello from Acme"})

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": response_body
    }
```

Click **Deploy** and wait for **Changes deployed**.

### Step B: Add the POST /order route

1. Open **API Gateway → acme-http-api → Routes**.
2. Click **Create**.
3. **Method:** `POST`. **Path:** `/order`.
4. Click **Create**.
5. Select the new **`POST /order`** route, click **Attach integration**, and choose the **existing** integration for `acme-hello` (do **not** create a new one). Save.

Because the `$default` stage auto-deploys, the new route is live immediately.

### Step C: (If you did the CORS step) allow POST

If you plan to call this from a browser, go to **CORS** and ensure `POST` is listed under **Access-Control-Allow-Methods** and `content-type` under **Access-Control-Allow-Headers**. For `curl` testing this is not required.

### Step D: Test with curl

Replace the host with your Invoke URL:

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -d '{"item":"widget","qty":3}' \
  https://abc123xyz.execute-api.us-east-1.amazonaws.com/order
```

**Expected result:**

```
HTTP/2 200
content-type: application/json
...

{"message": "Order received", "order": {"item": "widget", "qty": 3}}
```

### Validation

- The status line shows `HTTP/2 200`.
- The JSON response echoes back the `item` and `qty` you sent, proving the request body flowed from `curl` → API Gateway → Lambda (via `event["body"]`) → back to you.

### Cleanup for the challenge

No new resources were created (same Lambda, same integration, just an extra route). When you delete `acme-http-api` in the main cleanup, the `POST /order` route is removed with it. If you only want to remove the route: **API Gateway → acme-http-api → Routes → select `POST /order` → Delete**.
