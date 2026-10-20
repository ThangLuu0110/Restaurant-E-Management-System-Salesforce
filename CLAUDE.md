# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project overview

**Restaurant E-Management System (REMS)**: a Salesforce DX project (source format, no namespace) for running a restaurant: menu, tables, orders, kitchen workflow, payments, inventory and customer feedback.

- Single package directory: `force-app` (default)
- `sourceApiVersion`: **67.0**. Every new `*-meta.xml` must use `<apiVersion>67.0</apiVersion>`
- Login URL: `https://login.salesforce.com` (Developer Edition / Dev Hub)
- Status: early stage. The data model (custom objects + 1 Platform Event) is done; UI (LWC) is scaffolded only; **no Apex, triggers, flows, permission sets, layouts, tabs or app yet**.

## Repository layout

```
force-app/main/default/
├── objects/        # 8 custom objects + 1 platform event (see Data model)
└── lwc/
    └── menuPageComponent/   # Empty scaffold (App/Record/Home page targets) + placeholder Jest test
config/project-scratch-def.json   # Developer edition scratch org definition
scripts/apex, scripts/soql        # Anonymous Apex / SOQL scratchpad (still template samples)
```

New metadata goes in the standard folders under `force-app/main/default/` (`classes/`, `triggers/`, `flows/`, `permissionsets/`, `tabs/`, `applications/`, `layouts/`, ...).

## Data model

| Object | Purpose | Key fields / relationships |
|---|---|---|
| `Menu_Item__c` | Dish on the menu | `Category__c` (picklist: Appertizer, Main Course, Dessert, Beverage), `Price__c` (Currency), `Is_Available__c`, `Dietary_Tags__c` (multi-select: Vegetarian, Vegan, Gluten-Free, Spicy), `Prep_Time_Minute__c`, `Image_URL__c`, `Description__c` |
| `Inventory_Item__c` | Stock ingredient | `Quantity_On_Hand__c`, `Reorder_Threshold__c`, `Unit__c` |
| `Menu_Item_Ingredient__c` | Junction: recipe (Menu Item ↔ Inventory Item) | `Menu_Item__c` (**Master-Detail**), `Inventory_Item__c` (Lookup), `Quantity_Required__c` |
| `Table__c` | Dining table (name = AutoNumber `Table-{00}`) | `Seating_Capacity__c` (required), `Status__c` (Available, Occupied, Reversed, Cleaning), `Current_Order__c` → `Order__c` |
| `Order__c` | Customer order (label is currently "Orderr") | `Table__c` → `Table__c`, `User__c` → User, `Status__c` (New, Placed, Preparing, Ready, Served, Paid, Canceled), `Order_Time__c`, `Subtotal__c`, `Tax_Amount__c`, `Total_Amount__c` (**formula**: `Subtotal__c + Tax_Amount__c`) |
| `Order_Item__c` | Order line | `Order__c` (**Master-Detail**), `Menu_Item__c` (Lookup), `Chef__c` → User, `Quantity__c`, `Line_Subtotal__c`, `Status__c` (Pending, Accepted, Preparing, Ready, Served, Canceled), `Ready_Time__c`, `Special_Instructions__c` |
| `Payment__c` | Payment for an order | `Order__c` (Lookup), `Amount__c`, `Tip_Amount__c`, `Payment_Method__c` (Cash, Card, E-Wallet), `Status__c` (Pending, Completed, Refunded) |
| `Feedback__c` | Customer review | `Order__c` (Lookup), `Rating__c` (picklist 1–5), `Comments__c` |
| `Order_Item_Status_Change__e` | **Platform Event** (HighVolume, PublishImmediately) for real-time kitchen/floor updates | `Order_Id__c` (req), `Order_Item_Id__c` (req), `New_Status__c`, `Menu_Item_Name__c`, `Table_Number__c` |

Relationship notes:
- `Order__c` ↔ `Table__c` is a **two-way lookup** (`Order__c.Table__c` and `Table__c.Current_Order__c`). Keep them in sync in automation.
- All lookups use `deleteConstraint = SetNull`. Detail records (`Order_Item__c`, `Menu_Item_Ingredient__c`) are `ControlledByParent`. Everything else is `ReadWrite` sharing.
- Child relationship names are **singular**: from `Order__c` use `Order_Item__r`, `Payment__r`, `Feedback__r`; from `Menu_Item__c` use `Menu_Item_Ingredient__r`, `Order_Item__r`; from `Table__c` use `Order__r`. Example: `SELECT Id, (SELECT Id, Quantity__c FROM Order_Item__r) FROM Order__c`. Check `<relationshipName>` in the field XML before writing subqueries.

### Known data-model issues (confirm with the user before fixing)
- `Order_Item_Status_Change__e` text fields have `length = 10`. Salesforce IDs are 15/18 chars, so `Order_Id__c` / `Order_Item_Id__c` (and likely the name/status fields) are too short.
- Currency fields (`Price__c`, `Subtotal__c`, `Tax_Amount__c`, `Line_Subtotal__c`, `Amount__c`, `Tip_Amount__c`) have scale 0, while `Total_Amount__c` has scale 2.
- Typos: picklist value `Appertizer` (Appetizer), `Reversed` (Reserved), object label `Orderr`.
- Changing picklist API values or field types after data exists is destructive. Raise it first, don't silently rename.

## Commands

Default org alias in this workspace: `to-do-app` (from `.sf/config.json`). Verify it's the right org before deploying.

```bash
# Org
sf org login web --alias <alias>
sf config set target-org <alias>
sf org create scratch -f config/project-scratch-def.json -a rems-scratch -d -y 7

# Deploy / retrieve
sf project deploy start --source-dir force-app
sf project deploy start --source-dir force-app --dry-run          # validate only
sf project deploy start --metadata CustomObject:Order__c
sf project retrieve start --source-dir force-app/main/default/objects

# Apex tests (once classes exist)
sf apex run test --test-level RunLocalTests --code-coverage --result-format human --wait 10
sf apex run test --class-names MyClassTest --synchronous

# Scaffold
sf apex generate class --name OrderService --output-dir force-app/main/default/classes
sf apex generate trigger --name OrderItemTrigger --sobject Order_Item__c --output-dir force-app/main/default/triggers
sf lightning generate component --type lwc --name kitchenBoard --output-dir force-app/main/default/lwc

# Local quality checks
npm run lint                 # ESLint for LWC/Aura JS
npm run test:unit            # LWC Jest (sfdx-lwc-jest)
npm run test:unit:coverage
npm run prettier             # format (Apex + XML plugins enabled)
npm run prettier:verify
```

Pre-commit (Husky + lint-staged) runs Prettier on all staged sources, ESLint on LWC/Aura JS, and related Jest tests for changed LWC. Don't bypass it with `--no-verify`.

## Coding conventions

### General
- Format with the repo Prettier config (`trailingComma: none`, Apex + XML plugins, 4-space indent as in existing files).
- Use API names exactly as defined in metadata (e.g. `Prep_Time_Minute__c`, not `Prep_Time_Minutes__c`). Check `objects/**/fields/*.xml` instead of guessing.
- Don't hardcode record IDs, user IDs or picklist labels in logic. Use constants/Custom Metadata where reasonable.

### Apex (none written yet, follow these when adding)
- **One trigger per object**, logic-less: delegate to a handler class (e.g. `OrderItemTrigger` → `OrderItemTriggerHandler` → `OrderItemService`).
- Bulkify everything: no SOQL/DML inside loops, use collections and `Map<Id, SObject>`, and design for 200-record batches.
- Use `with sharing` by default. Use `inherited sharing` / `without sharing` only with a comment explaining why.
- Enforce CRUD/FLS: `WITH USER_MODE` in SOQL, `Database.insert(records, AccessLevel.USER_MODE)` or `Security.stripInaccessible` for `@AuraEnabled` methods.
- `@AuraEnabled(cacheable=true)` only for read-only methods. Wrap errors in `AuraHandledException`.
- Publish `Order_Item_Status_Change__e` via `EventBus.publish(...)` and check the `Database.SaveResult`s.
- Tests: `@IsTest` class per class (`<ClassName>Test`), a shared `TestDataFactory`, `@TestSetup`, `Test.startTest()/stopTest()`, real assertions (`Assert.areEqual`), bulk (200) + negative cases. Target ≥ 85% coverage (org minimum is 75%). Use `Test.getEventBus().deliver()` when testing platform event subscribers.

### LWC
- Folder/name in camelCase (`menuPageComponent`), markup tag kebab-case (`c-menu-page-component`).
- Prefer Lightning Data Service / `lightning/uiRecordApi` and base components (`lightning-card`, `lightning-datatable`, ...) before custom Apex.
- Import fields via `@salesforce/schema/Object__c.Field__c`, not string literals.
- Real-time kitchen/floor UI: subscribe to `/event/Order_Item_Status_Change__e` with `lightning/empApi`, and unsubscribe in `disconnectedCallback`.
- Every component has a Jest test in `__tests__/` that asserts real behavior. Replace the placeholder `expect(1).toBe(1)`. Mock wires and Apex with `@salesforce/sfdx-lwc-jest` utilities.
- `__tests__/` and `jsconfig.json` are excluded from deploys via `.forceignore`.

## Git workflow

- Default branch: `main`. Work on feature branches and merge via PR.
- Branch naming in use: `feat(REMS)/<short-description>` (e.g. `feat(REMS)/create-custom-objects`).
- Commit style in use: `feat(rems)/<summary>`. Keep the `type(rems)` prefix (`feat`, `fix`, `refactor`, `test`, `chore`, `docs`).
- Never commit `.sf/`, `.sfdx/`, `node_modules/`, or org credentials.

## Rules for Claude

- Only suggest solutions that are possible on the Salesforce platform (respect governor limits, metadata API support, and edition features of a Developer org).
- Before deploying, state the target org and use `--dry-run` first for non-trivial changes. Never deploy to production or run destructive changes (`destructiveChanges.xml`, field deletion, picklist value removal) without explicit confirmation.
- When adding a field/object, also consider the related permission set, page layout and list views. Ask if the user wants them, since none exist yet.
- After changing Apex, run the relevant tests. After changing LWC, run `npm run lint` and `npm run test:unit`.
- The user communicates in Vietnamese or English. Reply in the language of their message. Code, identifiers and commit messages stay in English.
