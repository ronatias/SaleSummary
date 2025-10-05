/**
 * SalesSummaryTests
 * -----------------
 * Purpose
 *  - End-to-end unit tests for SalesSummaryController and SalesService.
 *  - Validates happy path, null-argument guardrails, “no data” behavior, and
 *    negative security (CRUD/FLS) handling.
 *
 * Strategy
 *  - Uses @TestSetup to seed consistent test data shared by all tests.
 *  - Date math is relative to Date.today(), creating transactions both inside
 *    and outside the 12-month reporting window to prove the filter works.
 *  - Negative test locates a profile lacking READ on SalesTransaction__c to
 *    force the service’s access checks to throw (skipped gracefully if none).
 *
 * Limits/Performance
 *  - Each test executes at most a few lightweight SOQLs; no Batch/Async/DML loops.
 *  - No refactors—only comments are added.
 */
@IsTest
private class SalesSummaryTests {

    // Factory: build a User with a given Profile and unique Username for test isolation.
    private static User newUser(Id profileId, String alias, String emailLocal) {
        return new User(
            Alias = alias.left(8),
            Email = emailLocal + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = emailLocal,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = emailLocal + '+' + System.currentTimeMillis() + '@example.com',
            ProfileId = profileId
        );
    }

    /**
     * Helper: find a Profile that does NOT have READ on SalesTransaction__c.
     * Rationale: used to exercise the service’s CRUD/FLS exception path.
     * Behavior: returns null if all profiles currently have Read (orgs differ),
     *           and the calling test will skip gracefully in that case.
     */
    private static Id findProfileWithoutReadOnSalesTxn() {
        List<ObjectPermissions> perms = [
            SELECT PermissionsRead,
                   SObjectType,
                   Parent.IsOwnedByProfile,
                   Parent.ProfileId,
                   Parent.Profile.Name
            FROM ObjectPermissions
            WHERE Parent.IsOwnedByProfile = true
              AND SObjectType = 'SalesTransaction__c'
        ];
        for (ObjectPermissions p : perms) {
            if (p.PermissionsRead == false) {
                return p.Parent.ProfileId;
            }
        }
        return null;
    }

    /**
     * @TestSetup
     * Seeds:
     *  - Standard User “rep” who owns an Account “Alpha Corp”.
     *  - Two SalesTransaction__c inside the 12-month window (sum = 2000).
     *  - One historical SalesTransaction__c outside the window (ignored by query).
     *  - Another active User “other” with no owned data (for “no data” assertions).
     *
     * Notes:
     *  - Assumes a Profile named 'Standard User' exists (true in most orgs).
     */
    @TestSetup
    static void setupData() {
        Profile std = [
            SELECT Id, Name
            FROM Profile
            WHERE Name = 'Standard User'
            LIMIT 1
        ];
        User rep = newUser(std.Id, 'tstrep', 'rep');
        insert rep;

        Account a = new Account(Name = 'Alpha Corp', OwnerId = rep.Id);
        insert a;

        Date today = Date.today();
        Date midThisMonth = Date.newInstance(
            today.year(), 
            today.month(), 
            Math.min(15, Date.daysInMonth(today.year(), today.month()))
        );
        Date twoMonthsAgo = midThisMonth.addMonths(-2);

        // In-window transactions (count toward the 12-month series)
        SalesTransaction__c t1 = new SalesTransaction__c(
            Account__c = a.Id,
            SaleDate__c = midThisMonth,
            Amount__c = 1200
        );
        SalesTransaction__c t2 = new SalesTransaction__c(
            Account__c = a.Id,
            SaleDate__c = twoMonthsAgo,
            Amount__c = 800
        );

        // Out-of-window transaction (should not affect totals)
        SalesTransaction__c tOld = new SalesTransaction__c(
            Account__c = a.Id,
            SaleDate__c = midThisMonth.addYears(-2),
            Amount__c = 9999
        );

        insert new List<SalesTransaction__c>{ t1, t2, tOld };

        // Second active user with no ownership over the seeded Account
        User other = newUser(std.Id, 'tstoth', 'other');
        insert other;
    }

    /**
     * Happy path: controller returns exactly 12 points and totals match the
     * sum of in-window transactions (1200 + 800 = 2000).
     */
    @IsTest
    static void test_Controller_getMonthlyTotals_hasData() {
        User rep = [SELECT Id FROM User WHERE Email LIKE 'rep@%' LIMIT 1];

        Test.startTest();
        SalesService.MonthlySeries series = SalesSummaryController.getMonthlyTotals(rep.Id);
        Test.stopTest();

        System.assertNotEquals(null, series, 'Series must not be null');
        System.assertEquals(12, series.points.size(), 'Always returns 12 months');

        Decimal total = 0;
        for (SalesService.MonthTotal mt : series.points) {
            total += (mt.total == null ? 0 : mt.total);
        }
        System.assertEquals(2000, total, 'Expected 1200 + 800 across the 12-month window');
    }

    /**
     * Guardrail: null salesRepId must throw an AuraHandledException.
     * We assert on exception TYPE (message text may vary across locales).
     */
    @IsTest
    static void test_Controller_getMonthlyTotals_requiresParam() {
        Test.startTest();
        Boolean threw = false;
        try {
            SalesSummaryController.getMonthlyTotals(null);
            System.assert(false, 'Expected an exception for null salesRepId, but none was thrown.');
        } catch (AuraHandledException e) {
            threw = true; // correct exception type
        } catch (Exception e) {
            System.assert(false, 'Expected AuraHandledException, got: ' + e.getMessage());
        } finally {
            Test.stopTest();
        }
        System.assert(threw, 'Expected AuraHandledException for null salesRepId.');
    }

    /**
     * “No data” user: series still returns 12 points but all totals are zero.
     * Validates the zero-fill logic for missing months.
     */
    @IsTest
    static void test_Controller_getMonthlyTotals_noDataUser() {
        User other = [SELECT Id FROM User WHERE Email LIKE 'other@%' LIMIT 1];

        Test.startTest();
        SalesService.MonthlySeries series = SalesSummaryController.getMonthlyTotals(other.Id);
        Test.stopTest();

        System.assertNotEquals(null, series);
        System.assertEquals(12, series.points.size());
        Boolean anyNonZero = false;
        for (SalesService.MonthTotal mt : series.points) {
            if ((mt.total != null) && (mt.total != 0)) {
                anyNonZero = true; break;
            }
        }
        System.assertEquals(false, anyNonZero, 'Expected all months to be zero for user with no sales');
    }

    /**
     * getActiveUsers: returns at least one active user and the DTO fields are populated.
     * (Spot-checks mapping to UserOption without asserting on exact org user counts.)
     */
    @IsTest
    static void test_Controller_getActiveUsers_returnsList() {
        Test.startTest();
        List<SalesSummaryController.UserOption> opts = SalesSummaryController.getActiveUsers();
        Test.stopTest();

        System.assertNotEquals(null, opts, 'Options should not be null');
        System.assert(opts.size() > 0, 'Should return at least one active user');

        SalesSummaryController.UserOption sample = opts[0];
        System.assertNotEquals(null, sample.label, 'UserOption.label must be set');
        System.assertNotEquals(null, sample.value, 'UserOption.value must be set');
    }

    /**
     * Negative security: simulate a user whose Profile lacks READ on SalesTransaction__c.
     * Expectation: the service throws an AuraHandledException during access checks.
     * If every profile in the org currently has READ (uncommon), the test skips by design.
     */
    @IsTest
    static void test_Service_throws_when_NoObjectReadAccess() {
        Id noReadProfileId = findProfileWithoutReadOnSalesTxn();

        if (noReadProfileId == null) {
            System.debug('NOTE: No profile without Read on SalesTransaction__c was found; skipping negative access test.');
            System.assert(true);
            return;
        }

        User limited = newUser(noReadProfileId, 'nolstxn', 'nolstxn');
        insert limited;

        User rep = [SELECT Id FROM User WHERE Email LIKE 'rep@%' LIMIT 1];

        Boolean threw = false;
        Test.startTest();
        System.runAs(limited) {
            try {
                SalesService.getLast12MonthsTotalsByRep(rep.Id);
            } catch (AuraHandledException e) {
                threw = true;
                System.assert(
                    e.getMessage().contains('SalesTransaction__c'),
                    'Exception message should mention SalesTransaction__c access'
                );
            }
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Expected AuraHandledException due to missing object read access');
    }
}
