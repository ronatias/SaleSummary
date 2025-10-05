/**
 * SalesSummaryController
 * ----------------------
 * Purpose:
 *  - Server-side endpoints consumed by the Sales Summary LWC.
 *  - Enforces org-wide sharing rules (with sharing) and performs basic
 *    guardrails (null checks, CRUD/FLS) before delegating to the service layer.
 *
 * Security:
 *  - Runs WITH SHARING → respects record visibility for the running user.
 *  - Throws AuraHandledException with user-friendly messages on invalid input or access issues.
 *
 * Notes:
 *  - getMonthlyTotals is intentionally NOT cacheable to guarantee fresh aggregates on demand.
 *    If you later move to a pre-aggregated summary or add CDC/refreshApex, you can consider
 *    adding cacheable=true and explicitly refreshing when needed.
 *  - getActiveUsers is cacheable=true to leverage the Lightning storable cache (users list is relatively stable).
 *
 * Governor limits:
 *  - Each method performs at most a single SOQL query and no DML, well within limits for LWC usage.
 */
public with sharing class SalesSummaryController {

    /**
     * Returns a 12-month sales series for the specified sales rep (User Id).
     *
     * Input:
     *  - salesRepId (Id): required. The Account owner (rep) whose sales should be summarized.
     *
     * Behavior:
     *  - Validates the parameter and delegates the aggregation work to SalesService.getLast12MonthsTotalsByRep.
     *  - Relies on the service to perform CRUD/FLS checks for involved objects/fields.
     *
     * Output:
     *  - SalesService.MonthlySeries (List<MonthTotal> points with 12 items, including zero months).
     *
     * Errors:
     *  - AuraHandledException('Sales rep is required.') when input is null.
     */
    @AuraEnabled
    public static SalesService.MonthlySeries getMonthlyTotals(Id salesRepId) {
        if (salesRepId == null) {
            throw new AuraHandledException('Sales rep is required.');
        }
        return SalesService.getLast12MonthsTotalsByRep(salesRepId);
    }

    /**
     * Lightweight DTO for <lightning-combobox> options.
     *  - value: the record Id sent back to Apex when selected.
     *  - label: the text shown to the user.
     * Both fields are @AuraEnabled so LWC can serialize them.
     */
    public class UserOption {
        @AuraEnabled public Id value;
        @AuraEnabled public String label;
        public UserOption(Id v, String l) { value = v; label = l; }
    }

    /**
     * Returns up to 500 ACTIVE users to populate the Sales Rep combobox.
     *
     * Security:
     *  - Verifies the running user has READ access to the User object before querying.
     *
     * Caching:
     *  - cacheable=true → enables storable caching on the client for faster repeated loads.
     *
     * Query:
     *  - Filters on IsActive = true and orders by Name for a predictable UX.
     *  - LIMIT 500 protects from overly large picklists; adjust as needed per org size/UX.
     *
     * Output:
     *  - List<UserOption> where label = User.Name, value = User.Id.
     *
     * Considerations:
     *  - If you need to include inactive historical reps (for viewing old data),
     *    extend the query or provide a separate endpoint that unions recent rep Ids.
     */
    @AuraEnabled(cacheable=true)
    public static List<UserOption> getActiveUsers() {
        if (!Schema.SObjectType.User.isAccessible()) {
            throw new AuraHandledException('You do not have access to User.');
        }

        List<UserOption> options = new List<UserOption>();
        for (User u : [
            SELECT Id, Name
            FROM User
            WHERE IsActive = true
            ORDER BY Name
            LIMIT 500
        ]) {
            options.add(new UserOption(u.Id, u.Name));
        }
        return options;
    }
}
