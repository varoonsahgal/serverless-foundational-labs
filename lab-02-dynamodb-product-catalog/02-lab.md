# Lab 02: DynamoDB Product Catalog — Advanced Data Modeling and Access Patterns

## Estimated Duration

**~75 minutes**

## Scenario / Business Context

**Acme Retail** has outgrown its simple flat product list. The product team now needs:

- Products organized by **category** (Electronics, Home & Kitchen, Apparel)
- **Inventory tracking** with atomic stock-count updates that won't lose updates under high traffic
- **Discount codes** that automatically expire without a scheduled cleanup job
- Real-time **event streaming** for downstream analytics and personalization systems
- Fast catalog browsing by category, not just by individual product ID

Your job is to build a more sophisticated DynamoDB data model that supports all of these access patterns — and to do it without managing any database servers.

## Learning Objectives

By the end of this lab you will be able to:

- Create a DynamoDB table with a **composite primary key** (partition key + sort key).
- Explain the difference between **partition key**, **sort key**, and **composite primary key**.
- Add and retrieve items with diverse attribute types (String, Number, Boolean, List, Map).
- Create a **Global Secondary Index (GSI)** and understand when to use one vs. a Local Secondary Index (LSI).
- Query a table **by a GSI** to retrieve all products in a category.
- Distinguish **Filter Expressions** from **Key Condition Expressions** and explain the cost difference.
- Distinguish **Condition Expressions** from **Filter Expressions**.
- Use **UpdateItem with ADD** to implement an **atomic counter** for inventory tracking.
- Configure **Time to Live (TTL)** on a table to auto-expire records.
- Enable and explain **DynamoDB Streams** and describe their common use cases.
- Describe the difference between **On-demand** and **Provisioned** capacity modes.
- Clean up all resources to avoid ongoing charges.

## AWS Services Used

| Service | Purpose | Approximate Cost |
|---------|---------|-----------------|
| **Amazon DynamoDB** | Product catalog, orders, discount codes | ~$0 with on-demand + small data volume |
| **Amazon DynamoDB Streams** | Change event streaming | First 2.5M reads/month free, then $0.02/100K |

## Prerequisites

- An AWS account, signed in as an **IAM user** — not the root user.
- Your console Region is set to **US West (Oregon) — us-west-2**.

> **Region check:** Click the Region selector in the top-right of the console. It must show **US West (Oregon) us-west-2**. All ARNs and resources in this lab use `us-west-2`.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    DYNAMODB TABLES                              │
│                                                                 │
│  AcmeProducts                                                   │
│  ┌─────────────────────────────────────────────────┐           │
│  │  PK: category (String)                          │           │
│  │  SK: productId (String)                         │           │
│  │  Attributes: name, price, inStock, inventory,   │           │
│  │              brand, tags (List), specs (Map)     │           │
│  │                                                 │           │
│  │  GSI: ByPriceRange                              │           │
│  │  ├─ PK: category                               │           │
│  │  └─ SK: price (Number)                         │           │
│  └─────────────────────────────────────────────────┘           │
│           │                                                     │
│           ▼ (DynamoDB Streams)                                  │
│  ┌──────────────────┐                                          │
│  │  Change Stream   │ ──► Lambda / Kinesis / Analytics         │
│  └──────────────────┘                                          │
│                                                                 │
│  AcmeDiscountCodes (TTL enabled on expiresAt attribute)         │
│  ┌──────────────────────────────────────────────┐              │
│  │  PK: codeId (String)                         │              │
│  │  expiresAt: Unix epoch timestamp (Number)    │              │
│  │  discountPct: Number                         │              │
│  └──────────────────────────────────────────────┘              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Step-by-Step Instructions

### Step 1 — Open the DynamoDB Console and Confirm Region

1. Sign in to the AWS Management Console as your IAM user.
2. Confirm the **Region menu** (top-right) shows **US West (Oregon) us-west-2**. If not, click it and select the correct region.
3. In the top search bar, type `DynamoDB` and click the **DynamoDB** result.

> **AWS Mental Model — DynamoDB's Core Promise:**
> DynamoDB is a **fully managed NoSQL key-value and document database** that delivers single-digit millisecond performance at any scale. "Fully managed" means AWS handles hardware provisioning, patching, replication, backups, and scaling — you never SSH into a database server. "Any scale" means the same API call that works for 100 requests/day also works for 10 million requests/day; you don't rewrite your application.
>
> The trade-off: DynamoDB is not a relational database. There are no JOINs, no SQL, and no schema enforcement. You model your data around how you will access it — the exact opposite of SQL design, where you model for correctness and let queries figure out access.

---

### Step 2 — Create the AcmeProducts Table with Composite Key

**Why a composite key?** A single partition key (`productId`) lets you retrieve one product at a time by ID. But the product team's most common access pattern is "give me all products in the Electronics category." A composite key of `category` (partition) + `productId` (sort) stores all products in the same category together on the same physical partition, enabling efficient range queries.

1. In the left navigation pane, click **Tables**.
2. Click **Create table**.
3. For **Table name**, type exactly:
   ```
   AcmeProducts
   ```
4. For **Partition key**, type:
   ```
   category
   ```
   Type: **String**
5. For **Sort key** (click **Add sort key**), type:
   ```
   productId
   ```
   Type: **String**
6. Under **Table settings**, keep **Default settings** (On-demand capacity mode).
7. Click **Create table**.
8. Wait for the **Status** to show **Active** (typically under 60 seconds).

> **On-demand vs. Provisioned capacity:**
>
> | Mode | How it works | Best for |
> |------|-------------|---------|
> | **On-demand** | Pay per request; auto-scales instantly | Unpredictable traffic, development, low volume |
> | **Provisioned** | Reserve fixed read/write units in advance | Predictable, steady high-volume traffic |
>
> On-demand eliminates capacity planning and costs effectively zero with no traffic — ideal for this lab. Provisioned costs money even when idle (you reserve the capacity), but costs less at sustained high throughput.

**Validation checkpoint:** In **Tables**, `AcmeProducts` should show **Status: Active**. Click the table name and note the **Overview** tab shows Partition key = `category`, Sort key = `productId`.

---

### Step 3 — Add Eight Products Across Three Categories

1. Click **AcmeProducts** → **Explore table items** → **Create item**.
2. You'll see `category` and `productId` as required key attributes. Add the items below. For each, click **Add new attribute** and choose the correct type.

> **Tip:** After creating the first item, you'll recognize the pattern. The **JSON view** toggle in the top-right of the item editor is faster for pasting the full item — switch to JSON view and paste the item directly.

#### Electronics Category (3 items)

**Item 1 — Laptop:**
```json
{
  "category": {"S": "Electronics"},
  "productId": {"S": "ELEC-001"},
  "name": {"S": "UltraBook Pro 15"},
  "brand": {"S": "TechEdge"},
  "price": {"N": "1299.99"},
  "inStock": {"BOOL": true},
  "inventory": {"N": "47"},
  "tags": {"L": [{"S": "laptop"}, {"S": "portable"}, {"S": "business"}]},
  "specs": {"M": {
    "ram": {"S": "16GB"},
    "storage": {"S": "512GB SSD"},
    "display": {"S": "15.6-inch 4K"}
  }}
}
```

**Item 2 — Wireless Headphones:**
```json
{
  "category": {"S": "Electronics"},
  "productId": {"S": "ELEC-002"},
  "name": {"S": "SoundMax Wireless Pro"},
  "brand": {"S": "AudioWave"},
  "price": {"N": "199.95"},
  "inStock": {"BOOL": true},
  "inventory": {"N": "213"},
  "tags": {"L": [{"S": "audio"}, {"S": "wireless"}, {"S": "noise-cancelling"}]},
  "specs": {"M": {
    "batteryLife": {"S": "30 hours"},
    "connectivity": {"S": "Bluetooth 5.3"},
    "frequency": {"S": "20Hz-20kHz"}
  }}
}
```

**Item 3 — Smart Home Hub:**
```json
{
  "category": {"S": "Electronics"},
  "productId": {"S": "ELEC-003"},
  "name": {"S": "SmartHome Hub v3"},
  "brand": {"S": "HomeSense"},
  "price": {"N": "89.99"},
  "inStock": {"BOOL": false},
  "inventory": {"N": "0"},
  "tags": {"L": [{"S": "smart-home"}, {"S": "IoT"}, {"S": "hub"}]},
  "specs": {"M": {
    "protocols": {"S": "Zigbee, Z-Wave, Matter"},
    "maxDevices": {"S": "200"}
  }}
}
```

#### Home & Kitchen Category (3 items)

**Item 4 — Coffee Maker:**
```json
{
  "category": {"S": "Home & Kitchen"},
  "productId": {"S": "HOME-001"},
  "name": {"S": "BrewMaster 3000"},
  "brand": {"S": "CafePro"},
  "price": {"N": "149.00"},
  "inStock": {"BOOL": true},
  "inventory": {"N": "88"},
  "tags": {"L": [{"S": "coffee"}, {"S": "kitchen"}, {"S": "appliance"}]},
  "specs": {"M": {
    "capacity": {"S": "12 cups"},
    "programmable": {"S": "Yes"},
    "warranty": {"S": "2 years"}
  }}
}
```

**Item 5 — Stand Mixer:**
```json
{
  "category": {"S": "Home & Kitchen"},
  "productId": {"S": "HOME-002"},
  "name": {"S": "KitchenChef Stand Mixer Pro"},
  "brand": {"S": "KitchenChef"},
  "price": {"N": "299.99"},
  "inStock": {"BOOL": true},
  "inventory": {"N": "34"},
  "tags": {"L": [{"S": "baking"}, {"S": "mixer"}, {"S": "kitchen"}]},
  "specs": {"M": {
    "power": {"S": "600W"},
    "speeds": {"S": "10 speed settings"},
    "bowl": {"S": "5-quart stainless steel"}
  }}
}
```

**Item 6 — Air Purifier:**
```json
{
  "category": {"S": "Home & Kitchen"},
  "productId": {"S": "HOME-003"},
  "name": {"S": "PureAir HEPA Max"},
  "brand": {"S": "CleanSpace"},
  "price": {"N": "219.50"},
  "inStock": {"BOOL": true},
  "inventory": {"N": "62"},
  "tags": {"L": [{"S": "air-quality"}, {"S": "HEPA"}, {"S": "home"}]},
  "specs": {"M": {
    "coverage": {"S": "500 sq ft"},
    "filterType": {"S": "True HEPA H13"},
    "noiseLevel": {"S": "22dB at lowest"}
  }}
}
```

#### Apparel Category (2 items)

**Item 7 — Running Shoes:**
```json
{
  "category": {"S": "Apparel"},
  "productId": {"S": "APRL-001"},
  "name": {"S": "SwiftStep Trail Runner"},
  "brand": {"S": "AthleteGear"},
  "price": {"N": "119.95"},
  "inStock": {"BOOL": true},
  "inventory": {"N": "156"},
  "tags": {"L": [{"S": "shoes"}, {"S": "running"}, {"S": "trail"}]},
  "specs": {"M": {
    "material": {"S": "Breathable mesh"},
    "sole": {"S": "Vibram trail"},
    "drop": {"S": "6mm heel-to-toe"}
  }}
}
```

**Item 8 — Lightweight Jacket:**
```json
{
  "category": {"S": "Apparel"},
  "productId": {"S": "APRL-002"},
  "name": {"S": "WindBreaker Pro"},
  "brand": {"S": "OutdoorEdge"},
  "price": {"N": "85.00"},
  "inStock": {"BOOL": true},
  "inventory": {"N": "201"},
  "tags": {"L": [{"S": "jacket"}, {"S": "outdoor"}, {"S": "windproof"}]},
  "specs": {"M": {
    "material": {"S": "Ripstop nylon"},
    "waterRating": {"S": "DWR coated"},
    "packable": {"S": "Yes, folds to palm size"}
  }}
}
```

3. Create each item by switching to **JSON view**, pasting the JSON, and clicking **Create item**.

> **DynamoDB Type Codes in JSON:**
> - `{"S": "value"}` — String
> - `{"N": "123"}` — Number (stored as string internally; compared numerically)
> - `{"BOOL": true}` — Boolean
> - `{"L": [...]}` — List (ordered array of any types)
> - `{"M": {...}}` — Map (an embedded document of key-value pairs)
>
> The Map type (`specs`) is DynamoDB's equivalent of an embedded JSON object. It can be nested arbitrarily deep, though deeply nested structures are harder to update atomically.

**Validation checkpoint:** In **Explore table items**, run a **Scan**. You should see all **8 items** listed. Note that each item has different attributes — DynamoDB imposes no schema beyond the key attributes. An Apparel item's `specs` look completely different from an Electronics item's `specs`.

> **Common Beginner Mistake:** Expecting DynamoDB to validate attribute types across items. It won't. If you put `"inventory": {"S": "lots"}` on one item and `"inventory": {"N": "47"}` on another, DynamoDB accepts both without complaint. Schema enforcement is your application's responsibility.

---

### Step 4 — Query Products by Category (Composite Key Query)

Now you'll see the value of the composite key design.

1. In **Explore table items**, switch from **Scan** to **Query**.
2. In the **Partition key** field (labeled `category`), type:
   ```
   Electronics
   ```
3. Leave the **Sort key** field empty (returns all items with that partition key).
4. Click **Run**.

You should see exactly **3 items** — the three Electronics products — returned efficiently. DynamoDB goes directly to the `Electronics` partition and returns only those items.

5. Run the same query with `category = Home & Kitchen` — you get **3 items**.
6. Run with `category = Apparel` — you get **2 items**.

> **Why this is efficient:** With a composite key, all items sharing the same partition key (`category`) are stored together on the same physical partition. A Query with a partition key value reads *only* those items — no full-table read required. Compare this to a Scan + filter, which reads all 8 items and then discards the ones that don't match.

> **Key Condition Expression vs. Filter Expression — the most important DynamoDB performance concept:**
>
> | | Key Condition Expression | Filter Expression |
> |-|--------------------------|-------------------|
> | **Applied at** | The storage layer — before data is returned | After data is read — post-retrieval |
> | **Reads billed** | Only matching items | ALL items read, even filtered-out ones |
> | **Use for** | Keys and GSI key attributes ONLY | Non-key attributes |
>
> Example: If you run `Scan` and then add a filter `price > 100`, DynamoDB reads all 8 items (billing you for 8 read units), applies the filter, and returns only the matching ones. If you use a Query on a GSI keyed on price, DynamoDB reads only the matching items. Same results, vastly different cost at scale.

---

### Step 5 — Create a Global Secondary Index (GSI) for Price Queries

The product team needs to find all products in a category with a price below a threshold. The primary key (`category` + `productId`) can query by category efficiently, but cannot filter by price without reading all items in the category. A **GSI** solves this.

A **Global Secondary Index** is a separate index with its own partition key and optional sort key, which can be completely different from the table's primary key. It allows efficient queries on non-primary-key attributes.

1. In the **Tables** list, click **AcmeProducts**.
2. Click the **Indexes** tab.
3. Click **Create index**.
4. Fill in:
   - **Partition key:** `category` (String) — same partition key as the table
   - **Sort key:** `price` (Number) — now we can range-query by price within a category
   - **Index name:** `category-price-index`
   - **Attribute projections:** **All** (copies all item attributes into the index; simpler but uses more storage)
5. Click **Create index**.
6. Wait for the index status to show **Active** (usually 1-2 minutes for a small table).

> **GSI vs. LSI — when to use which:**
>
> | | Global Secondary Index (GSI) | Local Secondary Index (LSI) |
> |-|------------------------------|------------------------------|
> | **Partition key** | Any attribute (can differ from table PK) | Must match table's partition key |
> | **Sort key** | Any attribute | Any non-key attribute |
> | **Create when** | Any time | **Only at table creation** |
> | **Read consistency** | Eventually consistent only | Strongly consistent available |
> | **Use case** | Entirely different access pattern | Same partition, different sort order |
>
> For our case — querying by price range within a category — a GSI is the right choice because we can create it now (the table already exists), and the partition key can remain `category`.

**Validation checkpoint:** The **Indexes** tab should show `category-price-index` with status **Active**.

---

### Step 6 — Query by Category and Price Range Using the GSI

1. Go to **AcmeProducts** → **Explore table items**.
2. Switch to **Query**.
3. You'll see a dropdown that says **Table: AcmeProducts** — click it and select the index **category-price-index**.
4. In the **Partition key** field (`category`), type:
   ```
   Electronics
   ```
5. Under **Sort key condition**, select **Less than or equal to (≤)** and enter:
   ```
   200
   ```
6. Click **Run**.

You should see **2 items** returned — the `SoundMax Wireless Pro` ($199.95) and the `SmartHome Hub v3` ($89.99). The `UltraBook Pro 15` at $1,299.99 is excluded by the price condition at the index level — no extra read charges for it.

> **What Is Happening Behind the Scenes?**
> The GSI is a separate internal structure that DynamoDB maintains alongside the main table. When you write or update an item in the main table, DynamoDB automatically propagates the change to all relevant GSIs in the background. You never manually update a GSI. This propagation is asynchronous — by default, GSIs are **eventually consistent** (there is a brief lag after a write before the GSI reflects it). For most catalog-style applications, this lag (typically milliseconds to a second) is acceptable.

---

### Step 7 — Filter Expressions vs. Condition Expressions

These two DynamoDB concepts have similar names but completely different purposes. Confusing them causes bugs.

#### Filter Expressions — Post-Read Filtering (for reads)

Add a filter to a scan to find only in-stock items. Note: the filter is applied AFTER all items are read.

1. Go to **Explore table items** → **Scan**.
2. Expand **Filters**.
3. Add:
   - **Attribute name:** `inStock`
   - **Condition:** `=`
   - **Value:** `true` (Boolean)
4. Click **Run**.

You should see only the items where `inStock = true`. The scan read all 8 items but returned only the matching ones.

> **Cost caution:** On this 8-item table, the difference is trivial. On a 10-million-item table, filtering out 9.9 million items after reading them all is extremely expensive. Design your keys and GSIs so that filtering is rarely needed for high-volume queries.

#### Condition Expressions — Write Guards (for writes)

Condition expressions are completely different. They are **guards on write operations** — a write succeeds only if the condition is true at the time of the write. If the condition is false, the write fails with a `ConditionalCheckFailedException`.

Example: "Only update the inventory count if the item currently exists."

In a real application (using AWS CLI or SDK), this looks like:

```bash
aws dynamodb update-item \
  --table-name AcmeProducts \
  --region us-west-2 \
  --key '{"category":{"S":"Electronics"},"productId":{"S":"ELEC-001"}}' \
  --condition-expression "attribute_exists(productId)" \
  --update-expression "SET inventory = inventory - :dec" \
  --expression-attribute-values '{":dec":{"N":"1"}}'
```

The `--condition-expression "attribute_exists(productId)"` ensures the update only runs if the item exists. If the item was deleted between the time you read it and the time you write it, the update fails safely instead of creating a ghost item.

> **Filter Expression vs. Condition Expression — remember this table:**
>
> | | Filter Expression | Condition Expression |
> |-|-------------------|---------------------|
> | **Used with** | Read operations (Query, Scan) | Write operations (PutItem, UpdateItem, DeleteItem) |
> | **Applied at** | After data is read | Before write is applied |
> | **If condition fails** | Just filters results | Raises `ConditionalCheckFailedException` |
> | **Billed reads** | All items scanned, even filtered out | N/A — it's a write guard |

---

### Step 8 — Atomic Counters for Inventory Tracking

Acme Retail's inventory system must handle concurrent customers buying the last unit of a product simultaneously. A naive approach — "read the count, subtract 1, write back" — has a **race condition**: if two customers read `inventory = 1` at the same time, both subtract 1 and write back `inventory = 0`, but two units were "sold" despite only one existing.

DynamoDB solves this with **UpdateItem + ADD**, which is a **server-side atomic operation**. The increment/decrement happens atomically on the server — no read-before-write race condition is possible.

#### Update inventory from the console

1. Go to **AcmeProducts** → **Explore table items**.
2. Find the `ELEC-001` item (UltraBook Pro 15) and click **Edit item**.
3. Find the `inventory` attribute (currently `47`).
4. Change the value to `46`.
5. Click **Save changes**.

The console uses a simple overwrite here. In production, you would use the AWS CLI or SDK with `UpdateItem` and an `ADD` expression for true atomicity:

```bash
aws dynamodb update-item \
  --table-name AcmeProducts \
  --region us-west-2 \
  --key '{"category":{"S":"Electronics"},"productId":{"S":"ELEC-001"}}' \
  --update-expression "ADD inventory :dec" \
  --expression-attribute-values '{":dec":{"N":"-1"}}' \
  --return-values UPDATED_NEW
```

The `ADD` operation with a negative number is DynamoDB's atomic decrement. You can also use `SET inventory = inventory - :dec`, which DynamoDB evaluates atomically.

> **What Is Happening Behind the Scenes?**
> When DynamoDB receives an `UpdateItem` with `ADD inventory :dec`, it applies the arithmetic directly to the stored value on the partition, inside a single write operation, without any separate read step. This is the same concept as an `ATOMIC_LONG.decrementAndGet()` in Java — no external locking required. This is why DynamoDB is safe for inventory-style counters even under high concurrency.

> **Common Beginner Mistake:** Implementing inventory updates with read-then-write from application code. Under concurrent load, this loses updates. Always use server-side expressions for counters.

---

### Step 9 — Time to Live (TTL) for Discount Codes

Acme Retail runs time-limited promotions. Discount codes should automatically expire and disappear from the database — with no scheduled cleanup job needed. **DynamoDB TTL** handles this natively.

#### Create the AcmeDiscountCodes table

1. **DynamoDB → Tables → Create table**.
2. **Table name:** `AcmeDiscountCodes`
3. **Partition key:** `codeId` (String)
4. Leave sort key empty.
5. Keep **Default settings** (On-demand). Click **Create table**.
6. Wait for **Active** status.

#### Enable TTL on the table

1. Open **AcmeDiscountCodes** → **Additional settings** tab.
2. Under **Time to Live (TTL)**, click **Turn on** (the button may also appear as "Enable" in some console versions).
3. In the **TTL attribute** field, type:
   ```
   expiresAt
   ```
4. Click **Save**.

> **TTL Attribute Rules:**
> - The TTL attribute must be a **Number** type.
> - Its value must be a **Unix epoch timestamp in seconds** (not milliseconds). Example: `1784400000` = a date in July 2026.
> - DynamoDB checks the attribute every few minutes. Items are typically deleted within **48 hours** after their TTL timestamp passes — not exactly at expiry.
> - While an item is past its TTL but not yet deleted, it still appears in reads. Your application should check `expiresAt` if exact expiry timing matters.

#### Add discount code items

1. **AcmeDiscountCodes → Explore table items → Create item**.

   **Item 1 — Active code (expires far in future):**
   ```json
   {
     "codeId": {"S": "SAVE20"},
     "discountPct": {"N": "20"},
     "minOrderTotal": {"N": "50.00"},
     "description": {"S": "20% off orders over $50"},
     "expiresAt": {"N": "1893456000"}
   }
   ```
   (1893456000 = January 1, 2030 in Unix time — far future, won't expire during the lab)

   **Item 2 — Expired code (past TTL):**
   ```json
   {
     "codeId": {"S": "WELCOME10"},
     "discountPct": {"N": "10"},
     "minOrderTotal": {"N": "0"},
     "description": {"S": "10% welcome discount — expired"},
     "expiresAt": {"N": "1000000000"}
   }
   ```
   (1000000000 = September 9, 2001 — well past, TTL will mark it for deletion)

2. Create both items.

> **What Is Happening Behind the Scenes?**
> DynamoDB's TTL worker scans partitions in the background looking for items where the TTL attribute value is less than the current Unix timestamp. When found, DynamoDB generates a `DELETE` operation for those items. This delete is propagated to DynamoDB Streams (as a `REMOVE` event with `userIdentity.type = "Service"` and `userIdentity.principalId = "dynamodb.amazonaws.com"`), so downstream consumers can react to TTL-driven expirations differently from application-driven deletes.

> **Cost Awareness:** TTL deletes are **free** — DynamoDB does not charge you for the delete operations performed by TTL. This is a significant advantage over writing your own cleanup Lambda on a schedule, which would incur both Lambda execution costs and DynamoDB write costs.

**Validation checkpoint:** Run a Scan on `AcmeDiscountCodes`. Both items appear — including the expired one, since TTL deletion can take up to 48 hours. In a production system, your code would include `WHERE expiresAt > :now` in its queries to filter out expired codes proactively.

---

### Step 10 — Enable and Understand DynamoDB Streams

**DynamoDB Streams** captures a time-ordered sequence of item-level modifications to a table. Every time an item is created, updated, or deleted, a stream record is written. Downstream systems (Lambda functions, Kinesis Data Streams consumers) can read this stream to react to changes in near-real-time.

#### Use cases for DynamoDB Streams at Acme Retail:

| Event | Downstream reaction |
|-------|---------------------|
| New product added | Sync to Elasticsearch search index |
| Inventory reaches 0 | Send alert to restocking system |
| Order placed | Trigger email confirmation Lambda |
| Discount code expires (TTL) | Remove from promotional cache |
| Product price updated | Invalidate CDN/product page cache |

#### Enable Streams on AcmeProducts

1. Open **AcmeProducts** → **Exports and streams** tab.
2. Under **DynamoDB stream details**, click **Enable**.
3. Choose **View type:** **New and old images** — this captures both the before-state and after-state of every changed item, giving downstream consumers full context.
4. Click **Enable stream**.

> **Stream view type options:**
>
> | Option | What the stream record contains |
> |--------|--------------------------------|
> | **KEYS_ONLY** | Only the key attributes of the changed item |
> | **NEW_IMAGE** | The entire item after the change |
> | **OLD_IMAGE** | The entire item before the change |
> | **NEW_AND_OLD_IMAGES** | Both before and after — most useful for auditing and change detection |

> **What Is Happening Behind the Scenes?**
> When you enable a stream, DynamoDB creates a separate sharded log alongside the table. Every write to the table generates a stream record. Records in the stream are retained for **24 hours**. You can connect an AWS Lambda trigger directly to the stream, and Lambda will automatically poll the stream and invoke your function with batches of change records.

**Validation checkpoint:** The **Exports and streams** tab should now show **DynamoDB stream: Enabled** with your chosen view type and a **Latest stream ARN** visible. You won't connect a Lambda consumer in this lab — but the stream ARN is what you'd provide to a Lambda event source mapping.

> **Cost Awareness:** DynamoDB Streams charges per stream read request. The first 2.5 million stream read requests per month are free. With a Lambda trigger, Lambda polls the stream roughly once per second per shard — typically well within the free tier for development workloads.

---

### Step 11 — Advanced Queries: Sort Key Expressions

The composite key design pays off here. Because `productId` is the sort key and DynamoDB stores items sorted by it within each partition, you can do efficient range queries on the sort key.

1. **AcmeProducts → Explore table items → Query**.
2. **Partition key (`category`):** `Apparel`
3. Under **Sort key condition**, select **Begins with** and enter: `APRL`
4. Click **Run** — returns both Apparel items.

5. Change to category `Electronics`, sort key condition: **Between**, values `ELEC-001` and `ELEC-002`.
6. Click **Run** — returns only the Laptop and Headphones (ELEC-001 and ELEC-002), not the Hub (ELEC-003).

Available sort key conditions in DynamoDB:

| Condition | Example use |
|-----------|------------|
| `=` | Exact match on sort key |
| `<`, `<=`, `>`, `>=` | Numeric or lexicographic range |
| `Between` | Inclusive range on sort key value |
| `Begins with` | Prefix match (String sort keys only) |

---

## Key Takeaways

- **DynamoDB's primary key** is either a single partition key or a composite key (partition + sort). Choose based on your most important access patterns.
- **Composite keys** store related items together and enable efficient range queries — at the cost of requiring both key values for direct item access.
- **GSIs** are additional query entry points for non-primary-key attributes. Create them whenever you have a critical access pattern that the primary key doesn't support.
- **Filter Expressions** happen after data is read (you're still billed for everything scanned). **Key Condition Expressions** happen before — much cheaper at scale.
- **Condition Expressions** are write-time guards, not read-time filters. Use them to implement optimistic locking and prevent overwrites.
- **Atomic counters** (`ADD` / `SET field = field + :val`) execute server-side without a read-before-write step — essential for correct inventory tracking under concurrency.
- **TTL** auto-expires items for free — ideal for session tokens, discount codes, and any time-limited data.
- **DynamoDB Streams** captures every item change as an ordered event stream, enabling real-time downstream processing without polling.
- **On-demand** mode costs effectively zero for idle tables and handles bursts automatically — always the right default for development and low-predictability workloads.

---

## Challenges

> Try each challenge yourself before looking at the solutions file.

---

### Challenge 1 — Projection Expressions and Sparse Attributes

The product team needs an API that returns only `name`, `price`, and `inStock` for each item in the `Home & Kitchen` category — not the full item with specs, tags, and brand. Returning fewer attributes reduces response size and speeds up the API.

**Your task:**

1. Using the DynamoDB console's **Query** mode on `AcmeProducts`, query the `Home & Kitchen` category.
2. Add a **Projection Expression** (in the Filters/attributes section of the query UI) to return only `name`, `price`, and `inStock`.
3. Explain in writing: why does DynamoDB still read the full item internally even when a projection expression is specified? What is and isn't saved by using projection expressions?
4. Write the AWS CLI command (you don't need to run it) that would perform this query with projection expression from a terminal.

See `02-solutions.md` → Challenge 1 for the complete answer including the CLI command.

---

### Challenge 2 — Sparse GSI Design for Clearance Items

The marketing team wants to quickly find all **clearance items** across all categories. Only about 5% of products are ever on clearance at any time. A naive approach would add a `clearance = true` attribute to clearance items and use a filter expression — but that reads every product on every scan.

The **sparse GSI** pattern is the DynamoDB-idiomatic solution: add a `clearancePrice` attribute only to clearance items. Create a GSI on `clearancePrice`. Since DynamoDB only indexes items that actually have the GSI key attribute, the GSI contains only clearance items — even though the main table has 8 regular products.

**Your task:**

1. Update exactly **2 of your 8 products** to add a `clearancePrice` attribute (a Number, less than their regular price).
2. Create a new GSI on `AcmeProducts`:
   - **Partition key:** `clearancePrice` (Number) — or design a better key structure
   - **Index name:** `clearance-index`
3. Explain the design problem with using `clearancePrice` as a partition key, and propose a better design using a `onClearance` string attribute.
4. Create items with the better design and verify that querying the GSI returns only clearance items.

See `02-solutions.md` → Challenge 2 for the complete design explanation and steps.

---

## Cleanup Instructions

Delete all resources created in this lab to avoid ongoing storage charges.

1. **Delete the AcmeProducts table** (this also removes its GSIs and Streams):
   - **DynamoDB → Tables** → select the checkbox next to **AcmeProducts** → **Delete**.
   - In the confirmation dialog, type `confirm` (or `delete` as prompted) and click **Delete table**.

2. **Delete the AcmeDiscountCodes table:**
   - **DynamoDB → Tables** → select checkbox next to **AcmeDiscountCodes** → **Delete**.
   - Type `confirm`. Click **Delete table**.

3. **Confirm** both tables no longer appear in the Tables list.

> **Cost Awareness:** DynamoDB charges for data stored in both the table and its GSIs. Deleting the table removes all storage costs immediately. With on-demand mode and no traffic, this 8-item table costs a fraction of a cent — but building the habit of cleaning up resources is critical before working with larger real-world datasets.
