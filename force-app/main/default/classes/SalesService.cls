/**
 * SalesService
 * ------------
 * Purpose:
 *  - Pure domain/service layer that aggregates SalesTransaction__c into a
 *    12-point monthly time series for a given sales rep.
 *
 * Design:
 *  - WITH SHARING → respects record visibility of the running user.
 *  - No UI concerns and no DML; safe to call from LWC or other Apex.
 *  - Performs explicit CRUD/FLS checks before querying.
 *
 * Performance:
 *  - Single aggregate SOQL with GROUP BY YEAR/MONTH (max 12 groups in the window).
 *  - Memory footprint is small (map of ≤12 entries, then a 12-element list).
 *  - The filter uses a selective date range plus Account owner; works well on large data sets.
 *
 * Time semantics:
 *  - Date.today() and CALENDAR_YEAR/MONTH use the running user’s time zone.
 *  - The window is inclusive of the current calendar month and excludes the first day of the next month.
 *
 * Attribution model:
 *  - “Sales rep” is defined as Account owner at query time
 *    (i.e., Account__r.OwnerId = :salesRepId). If Account ownership changes,
 *    historical attribution will follow the *current* owner. If you need
 *    attribution to remain fixed, consider denormalizing a Sales_Rep__c lookup
 *    on SalesTransaction__c and filtering on that instead.
 */
public with sharing class SalesService {

    /**
     * DTO for a single month’s total.
     * - month is 1..12.
     * - monthLabel is a display helper "YYYY-M" (no leading zero for month to keep logic simple).
     * - total is coerced to 2 decimal places for consistent currency display.
     */
    public class MonthTotal {
        @AuraEnabled public Integer year;
        @AuraEnabled public Integer month; // 1-12
        @AuraEnabled public String monthLabel; // e.g. "2025-03"
        @AuraEnabled public Decimal total;
        public MonthTotal(Integer y, Integer m, Decimal t) {
            year = y;
            month = m;
            monthLabel = String.valueOf(y) + '-' + m.format();
            total = t == null ? 0 : t.setScale(2); // normalize to 2 dp for UI presentation
        }
    }

    /**
     * DTO wrapper for the full series (exactly 12 points; missing months filled with zeros).
     */
    public class MonthlySeries {
        @AuraEnabled public List<MonthTotal> points;
        public MonthlySeries(List<MonthTotal> pts) { points = pts; }
    }

    /**
     * Build a 12-month series ending in the current calendar month (inclusive),
     * restricted to transactions on Accounts owned by the given salesRepId.
     *
     * Security:
     *  - Verifies object and field READ access for SalesTransaction__c (Amount__c, SaleDate__c, Account__c)
     *    and object access for Account before querying.
     *  - WITH SHARING ensures only visible records are aggregated.
     *
     * Query notes:
     *  - CALENDAR_YEAR/MONTH buckets by user time zone.
     *  - WHERE clause uses an inclusive lower bound and an exclusive upper bound to avoid off-by-one errors.
     *  - No fields from Account are selected; the relationship is only used for filtering by owner.
     *
     * Output:
     *  - Always returns a 12-element series in chronological order; months with no data return total = 0.
     */
    public static MonthlySeries getLast12MonthsTotalsByRep(Id salesRepId) {
        // --- CRUD & FLS checks (READ) ---
        if (!Schema.SObjectType.SalesTransaction__c.isAccessible()) {
            throw new AuraHandledException('You do not have access to SalesTransaction__c.');
        }
        if (!Schema.SObjectType.Account.isAccessible()) {
            throw new AuraHandledException('You do not have access to Account.');
        }
        // Field-level checks for fields used in SELECT/WHERE/GROUP BY clauses.
        if (!Schema.SObjectType.SalesTransaction__c.fields.Amount__c.isAccessible()
            || !Schema.SObjectType.SalesTransaction__c.fields.SaleDate__c.isAccessible()
            || !Schema.SObjectType.SalesTransaction__c.fields.Account__c.isAccessible()) {
            throw new AuraHandledException('You do not have permission to read required fields.');
        }

        // Calculate range: first day of current month minus 11 months (→ 12 months total),
        // and an exclusive upper bound at the first day of the next month.
        Date today = Date.today();
        Date firstOfThisMonth = Date.newInstance(today.year(), today.month(), 1);
        Date startDate = firstOfThisMonth.addMonths(-11); // 12 months window
        Date exclusiveEnd = firstOfThisMonth.addMonths(1);

        // Aggregate by month/year. The ORDER BY matches the GROUP BY to ensure chronological output.
        // Note: This filter attributes sales to the *current* Account owner.
        List<AggregateResult> rows = [
            SELECT CALENDAR_YEAR(SaleDate__c) y,
                   CALENDAR_MONTH(SaleDate__c) m,
                   SUM(Amount__c) s
            FROM SalesTransaction__c
            WHERE SaleDate__c >= :startDate
              AND SaleDate__c < :exclusiveEnd
              AND Account__r.OwnerId = :salesRepId
            GROUP BY CALENDAR_YEAR(SaleDate__c), CALENDAR_MONTH(SaleDate__c)
            ORDER BY CALENDAR_YEAR(SaleDate__c), CALENDAR_MONTH(SaleDate__c)
        ];

        // Build a quick lookup of (year-month) → sum for constant-time access when composing the 12 months.
        Map<String, Decimal> ymToSum = new Map<String, Decimal>();
        for (AggregateResult ar : rows) {
            Integer y = (Integer) ar.get('y');
            Integer m = (Integer) ar.get('m');
            Decimal s = (Decimal) ar.get('s');
            ymToSum.put(y + '-' + m, s == null ? 0 : s);
        }

        // Emit all 12 months in order, inserting 0 where the aggregate returned no row.
        List<MonthTotal> series = new List<MonthTotal>();
        Date iter = startDate;
        for (Integer i = 0; i < 12; i++) {
            Integer y = iter.year();
            Integer m = iter.month(); // 1..12
            Decimal sum = ymToSum.get(y + '-' + m);
            series.add(new MonthTotal(y, m, sum == null ? 0 : sum));
            iter = iter.addMonths(1);
        }

        return new MonthlySeries(series);
    }
}
