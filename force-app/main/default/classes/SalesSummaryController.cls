public with sharing class SalesSummaryController {
    @AuraEnabled
    public static SalesService.MonthlySeries getMonthlyTotals(Id salesRepId) {
        if (salesRepId == null) {
            throw new AuraHandledException('Sales rep is required.');
        }
        return SalesService.getLast12MonthsTotalsByRep(salesRepId);
    }

    // NEW: return active users for the combobox
    public class UserOption {
        @AuraEnabled public Id value;  // user Id
        @AuraEnabled public String label; // user Name
        public UserOption(Id v, String l) { value = v; label = l; }
    }

    @AuraEnabled(cacheable=true)
    public static List<UserOption> getActiveUsers() {
        // CRUD/FLS: verify we can read User
        if (!Schema.SObjectType.User.isAccessible()) {
            throw new AuraHandledException('You do not have access to User.');
        }
        // (Optional) You can add field-level checks if your org restricts standard fields.

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
