public with sharing class SalesService {
    public class MonthTotal {
        @AuraEnabled public Integer year;
        @AuraEnabled public Integer month; // 1-12
        @AuraEnabled public String monthLabel; // e.g. "2025-03"
        @AuraEnabled public Decimal total;
        public MonthTotal(Integer y, Integer m, Decimal t) {
            year = y;
            month = m;
            monthLabel = String.valueOf(y) + '-' + m.format();
            total = t == null ? 0 : t.setScale(2);
        }
    }

    public class MonthlySeries {
        @AuraEnabled public List<MonthTotal> points;
        public MonthlySeries(List<MonthTotal> pts) { points = pts; }
    }

    /**
     * Returns a 12-month series ending in the current calendar month (inclusive),
     * filtered by Accounts owned by the given sales rep (User Id).
     */
    public static MonthlySeries getLast12MonthsTotalsByRep(Id salesRepId) {
        // --- CRUD & FLS checks (READ) ---
        if (!Schema.SObjectType.SalesTransaction__c.isAccessible()) {
            throw new AuraHandledException('You do not have access to SalesTransaction__c.');
        }
        if (!Schema.SObjectType.Account.isAccessible()) {
            throw new AuraHandledException('You do not have access to Account.');
        }
        // Field-level checks
        if (!Schema.SObjectType.SalesTransaction__c.fields.Amount__c.isAccessible()
            || !Schema.SObjectType.SalesTransaction__c.fields.SaleDate__c.isAccessible()
            || !Schema.SObjectType.SalesTransaction__c.fields.Account__c.isAccessible()) {
            throw new AuraHandledException('You do not have permission to read required fields.');
        }

        // Calculate range: first day 12 months ago up to first day of next month
        Date today = Date.today();
        Date firstOfThisMonth = Date.newInstance(today.year(), today.month(), 1);
        Date startDate = firstOfThisMonth.addMonths(-11); // 12 months window
        Date exclusiveEnd = firstOfThisMonth.addMonths(1);

        // Aggregate by calendar month/year
        // NOTE: sharing is enforced by "with sharing" on the class, so record visibility is respected.
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

        // Build a map (year,month) → sum
        Map<String, Decimal> ymToSum = new Map<String, Decimal>();
        for (AggregateResult ar : rows) {
            Integer y = (Integer) ar.get('y');
            Integer m = (Integer) ar.get('m');
            Decimal s = (Decimal) ar.get('s');
            ymToSum.put(y + '-' + m, s == null ? 0 : s);
        }

        // Fill full 12-month series (including missing months as 0)
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
