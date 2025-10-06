# Sales Summary – README.dt

This document explains what’s needed to deploy and run the **Sales Summary** feature in your Salesforce org.

--------------------------------------------------------------------------------
1) PREREQUISITES
--------------------------------------------------------------------------------
- A Salesforce org (Sandbox or Scratch org recommended).
- Salesforce CLI installed (sf or sfdx).
- Source code available under:
  - force-app/main/default/classes/
    • SalesSummaryController.cls (+ .meta.xml)
    • SalesService.cls (+ .meta.xml)
    • SalesSummaryTests.cls (+ .meta.xml)
    • SalesTransactionGuardTests.cls (+ .meta.xml)
  - force-app/main/default/triggers/
    • SalesTransactionGuard.trigger (+ .meta.xml)
  - force-app/main/default/lwc/salesSummary/
    • salesSummary.js
    • salesSummary.html
    • salesSummary.js-meta.xml (exposed to Lightning App Builder)

--------------------------------------------------------------------------------
2) DATA MODEL – REQUIRED OBJECT & FIELDS
--------------------------------------------------------------------------------
Custom Object: SalesTransaction__c
- Account__c (Lookup → Account, Required)
- SaleDate__c (Date, Required)
- Amount__c (Currency or Number, 2 dp, Required)
Notes:
- Attribution is based on Account__r.OwnerId (Sales Rep) at query time.
- No validation rule is used; creation policy is enforced by a BEFORE INSERT trigger.

--------------------------------------------------------------------------------
3) PERMISSION SETS (REQUIRED)
--------------------------------------------------------------------------------
Create two Permission Sets and assign to users accordingly:

A) Sales Summary Access
- Apex Class Access:
  • SalesSummaryController
  • SalesService
- Object Permissions:
  • SalesTransaction__c: Read (and Create/Edit if creators should insert data)
  • Account: Read
  • User: Read
- Field Permissions:
  • Account__c, SaleDate__c, Amount__c: Read (Edit if creators)

B) Sales Summary Admin
- Includes Custom Permission:
  • Create_SalesTxn_On_Any_Account
  (Allows bypassing the trigger guard; see Trigger below.)

--------------------------------------------------------------------------------
4) TRIGGER ENFORCEMENT
--------------------------------------------------------------------------------
Trigger: SalesTransactionGuard (BEFORE INSERT on SalesTransaction__c)
- If Custom Permission Create_SalesTxn_On_Any_Account is granted → bypass guard.
- Otherwise:
  • Only the Account Owner can create a SalesTransaction__c for that Account.
  • If the current user has no Manager (User.ManagerId = null), the insert is blocked
    with a clear error message (manager existence validation).

Expected behavior:
- Non-admin, non-owner users cannot create a sales transaction for accounts they don’t own.
- Admins (with the custom permission in the Admin permission set) can create for any account.

--------------------------------------------------------------------------------
5) USER PICKER – WHO APPEARS IN THE UI
--------------------------------------------------------------------------------
Current implementation:
- Apex filters to users assigned to Permission Set "Sales_Summary_Access".

Planned next version (not yet implemented):
- Replace the combobox feed with a server-side type-ahead search method:
  • @AuraEnabled(cacheable=true) searchActiveReps(searchTerm, limitSize)
  • Debounced search in LWC (≥2 chars, ~300ms), returns 50–100 matches
  • Scales to thousands of users without sending one large list

--------------------------------------------------------------------------------
6) DEPLOYMENT
--------------------------------------------------------------------------------
Using Salesforce CLI (example commands):

# Authenticate org (choose one)
sf org login web -a MyOrg
# or
sfdx force:auth:web:login -a MyOrg

# Push/Deploy source
sf project deploy start
# or
sfdx force:source:deploy -p force-app

# (Optional) Run Apex tests and see coverage
sf apex run test --tests "SalesSummaryTests,SalesTransactionGuardTests" --result-format human --code-coverage
# or
sfdx force:apex:test:run -n "SalesSummaryTests,SalesTransactionGuardTests" -r human -c -w 30

--------------------------------------------------------------------------------
7) EXPOSING THE UI
--------------------------------------------------------------------------------
Lightning Web Component: salesSummary
- Go to Setup → App Builder (Lightning App Builder).
- Add the "Sales Summary" LWC to a Home page, App page, or Record page.
- Save & Activate the page for the desired app/profiles.

(If you want to CRUD the data via standard UI:)
- Create a Custom Object Tab for SalesTransaction__c (Setup → Tabs → Custom Object Tabs → New),
  then add it to your Lightning App navigation.

--------------------------------------------------------------------------------
8) FIRST-TIME SETUP CHECKLIST
--------------------------------------------------------------------------------
[ ] Create/verify SalesTransaction__c with required fields (Account__c, SaleDate__c, Amount__c).
[ ] Create Permission Set "Sales Summary Access" and grant:
    - Apex classes (SalesSummaryController, SalesService)
    - Object & Field permissions (SalesTransaction__c, Account, User)
[ ] Create Permission Set "Sales Summary Admin" and add the Custom Permission:
    - Create_SalesTxn_On_Any_Account
[ ] Assign "Sales Summary Access" to sales users.
[ ] Assign "Sales Summary Admin" to admins/lead users as needed.
[ ] Deploy the Apex classes, trigger, and LWC.
[ ] Add the LWC to a Lightning App page via App Builder and activate it.
[ ] (Optional) Create a Tab for SalesTransaction__c for data entry if not using another UI.

--------------------------------------------------------------------------------
9) RUNNING & EXPECTED UX
--------------------------------------------------------------------------------
- Select a Sales Rep in the UI (eligible users are those with "Sales_Summary_Access").
- Click "Show Summary" to load fresh data:
  • Spinner shows while loading.
  • Table lists the last 12 months; months with zero totals are styled in red.
  • If there’s no data, a toast displays and an inline message shows only after the first query.
- Changing the selected user clears previous results and messages.

--------------------------------------------------------------------------------
10) SECURITY NOTES
--------------------------------------------------------------------------------
- All Apex runs WITH SHARING.
- Apex performs explicit CRUD/FLS checks on:
  • SalesTransaction__c object and fields (Account__c, SaleDate__c, Amount__c)
  • Account object
- Friendly error messages are returned via AuraHandledException where appropriate.
- Trigger bypass requires the custom permission included in the Admin permission set.

--------------------------------------------------------------------------------
11) TESTING & COVERAGE
--------------------------------------------------------------------------------
- Two test classes:
  • SalesSummaryTests: happy path, guardrail (null rep id), no-data user, missing object access.
  • SalesTransactionGuardTests: owner insert allowed, non-owner blocked, bypass path, manager check.
- Current measured coverage: ~92% across classes + trigger (may vary slightly per org metadata).

To run:
- Setup → Apex Test Execution → Select classes → Run
- or use CLI commands in Section 6.

--------------------------------------------------------------------------------
12) PERFORMANCE & SCALABILITY
--------------------------------------------------------------------------------
- Server calls use a single aggregate SOQL over a bounded 12-month window.
- Current user feed returns all eligible users (no LIMIT); acceptable for moderate counts.
- Planned next version: type-ahead search to avoid large payloads at scale (thousands of users).

--------------------------------------------------------------------------------
13) KNOWN BEHAVIORS & LIMITATIONS
--------------------------------------------------------------------------------
- Attribution follows current Account ownership; historical re-ownership changes shift the summary.
- If a user lacks a Manager, the trigger blocks creation (unless Admin bypass permission is present).
- If many eligible users exist, initial list may be large; the future type-ahead approach addresses this.

--------------------------------------------------------------------------------
14) TROUBLESHOOTING
--------------------------------------------------------------------------------
- “You do not have access to the Apex class…” → Assign the appropriate Permission Set(s).
- “You do not have access to SalesTransaction__c…” → Grant object/field perms via Permission Sets.
- “Only owner may create…” error when inserting transactions:
  • Ensure the running user owns the Account OR use the Admin permission set for bypass.
- No data in the summary:
  • Ensure SalesTransaction__c rows exist within the last 12 months and the selected user owns the related Accounts.

--------------------------------------------------------------------------------
15) ROADMAP (NEXT VERSION)
--------------------------------------------------------------------------------
- Type-ahead user search (Apex searchActiveReps + debounced LWC UI).
- Optional CDC-based auto-refresh of the summary after transaction changes.
- Custom Labels for i18n and multi-currency-aware display.
- Advanced user filters (email/alias/region/role) and Permission Set Group support.
