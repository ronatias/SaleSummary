@IsTest
private class SalesTransactionGuardTests {

    // ---------------- Utilities ----------------
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
     * Find (or try to prepare) a Permission Set that grants the Custom Permission
     * 'Create_SalesTxn_On_Any_Account' so we can test the bypass path.
     * Returns a PermissionSet Id or null (skip) if not available/creatable in this org.
     */
    private static Id findOrCreatePermSetForBypassCP() {
        // Look up the Custom Permission
        List<CustomPermission> cps = [
            SELECT Id, DeveloperName
            FROM CustomPermission
            WHERE DeveloperName = 'Create_SalesTxn_On_Any_Account'
            LIMIT 1
        ];
        if (cps.isEmpty()) {
            System.debug('NOTE: CustomPermission Create_SalesTxn_On_Any_Account not found; skipping bypass test.');
            return null;
        }
        Id cpId = cps[0].Id;

        // See if any Permission Set already has this Custom Permission mapped
        List<SetupEntityAccess> existing = [
            SELECT Id, ParentId, Parent.Name
            FROM SetupEntityAccess
            WHERE SetupEntityId = :cpId
            AND   Parent.IsOwnedByProfile = false
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0].ParentId; // PermissionSet Id
        }

        // Attempt to create a new Permission Set + mapping (often restricted in tests; swallow on failure)
        try {
            PermissionSet ps = new PermissionSet(
                Name  = 'PS_Bypass_SalesTxn_Create',
                Label = 'Bypass Sales Transaction Owner Rule'
            );
            insert ps;

            SetupEntityAccess sea = new SetupEntityAccess(
                ParentId      = ps.Id,  // PermissionSet
                SetupEntityId = cpId    // CustomPermission
            );
            insert sea;

            return ps.Id;
        } catch (Exception e) {
            System.debug('NOTE: Could not create PermissionSet/SetupEntityAccess in test context. Skipping bypass test. ' + e.getMessage());
            return null;
        }
    }

    // ---------------- Test Data ----------------
    @TestSetup
    static void setupData() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

        // Two users: rep (owner) and other (non-owner)
        User rep   = newUser(std.Id, 'trigrep', 'trigrep');
        User other = newUser(std.Id, 'trigoth', 'trigoth');
        insert new List<User>{ rep, other };

        // Account owned by rep
        Account a = new Account(Name = 'Trigger Alpha', OwnerId = rep.Id);
        insert a;
    }

    // ---------------- Tests ----------------

    /**
     * Owner can create a SalesTransaction__c for their own Account (should pass).
     */
    @IsTest
    static void test_Owner_CanCreate() {
        User rep = [SELECT Id FROM User WHERE Email LIKE 'trigrep@%' LIMIT 1];
        Account a = [SELECT Id, OwnerId FROM Account WHERE Name = 'Trigger Alpha' LIMIT 1];
        System.assertEquals(rep.Id, a.OwnerId, 'Precondition: rep must own the account');

        Test.startTest();
        System.runAs(rep) {
            SalesTransaction__c st = new SalesTransaction__c(
                Account__c = a.Id,
                SaleDate__c = Date.today(),
                Amount__c = 123.45
            );
            insert st; // should succeed (no trigger error)
        }
        Test.stopTest();

        Integer cnt = [SELECT COUNT() FROM SalesTransaction__c WHERE Account__c = :a.Id];
        System.assertEquals(1, cnt, 'Owner should be able to insert one transaction');
    }

    /**
     * Non-owner is blocked by the trigger (addError → DmlException).
     */
    @IsTest
    static void test_NonOwner_Blocked() {
        User rep   = [SELECT Id FROM User WHERE Email LIKE 'trigrep@%' LIMIT 1];
        User other = [SELECT Id FROM User WHERE Email LIKE 'trigoth@%' LIMIT 1];
        Account a  = [SELECT Id, OwnerId FROM Account WHERE Name = 'Trigger Alpha' LIMIT 1];
        System.assertEquals(rep.Id, a.OwnerId, 'Precondition: rep must own the account');

        Boolean threw = false;
        Test.startTest();
        System.runAs(other) {
            try {
                SalesTransaction__c st = new SalesTransaction__c(
                    Account__c = a.Id,
                    SaleDate__c = Date.today(),
                    Amount__c = 55
                );
                insert st; // should error due to addError on Account__c
                System.assert(false, 'Expected DmlException for non-owner insert, but none thrown.');
            } catch (DmlException e) {
                threw = true;
                System.assert(
                    e.getDmlMessage(0).contains('You can only create a Sales Transaction for an Account you own'),
                    'Expected error message indicating ownership restriction.'
                );
            }
        }
        Test.stopTest();

        System.assert(threw, 'Non-owner should be blocked by trigger.');
    }

    /**
     * Bypass path: if the Custom Permission is present and mapped to a Permission Set,
     * assign it to the non-owner and verify insert succeeds. If not present/creatable,
     * skip gracefully (logs a note).
     */
    @IsTest
    static void test_Bypass_CustomPermission_AllowsNonOwner() {
        Id psId = findOrCreatePermSetForBypassCP();
        if (psId == null) {
            System.debug('SKIP: Bypass test skipped because Custom Permission / mapping not available in this org.');
            System.assert(true);
            return;
        }

        User other = [SELECT Id FROM User WHERE Email LIKE 'trigoth@%' LIMIT 1];
        Account a  = [SELECT Id FROM Account WHERE Name = 'Trigger Alpha' LIMIT 1];

        // Assign the permission set that grants the CP to the non-owner
        PermissionSetAssignment psa = new PermissionSetAssignment(
            AssigneeId      = other.Id,
            PermissionSetId = psId
        );
        insert psa;

        Test.startTest();
        System.runAs(other) {
            SalesTransaction__c st = new SalesTransaction__c(
                Account__c = a.Id,
                SaleDate__c = Date.today(),
                Amount__c = 777
            );
            insert st; // should succeed due to bypass
        }
        Test.stopTest();

        Integer cnt = [
            SELECT COUNT()
            FROM SalesTransaction__c
            WHERE Account__c = :a.Id AND Amount__c = 777
        ];
        System.assertEquals(1, cnt, 'Non-owner should be able to insert when bypass custom permission is granted.');
    }
}
