trigger SalesTransactionGuard on SalesTransaction__c (before insert) {
    // Allow bypass via custom permission
    Boolean bypass = FeatureManagement.checkPermission('Create_SalesTxn_On_Any_Account');

    if (bypass) return;

    Set<Id> accIds = new Set<Id>();
    for (SalesTransaction__c st : Trigger.new) if (st.Account__c != null) accIds.add(st.Account__c);

    Map<Id, Account> accMap = accIds.isEmpty()
        ? new Map<Id, Account>()
        : new Map<Id, Account>([SELECT Id, OwnerId FROM Account WHERE Id IN :accIds]);

    Id me = UserInfo.getUserId();
    for (SalesTransaction__c st : Trigger.new) {
        if (st.Account__c == null) continue;
        Account a = accMap.get(st.Account__c);
        if (a != null && a.OwnerId != me) {
            st.Account__c.addError('You can only create a Sales Transaction for an Account you own.');
        }
    }
}