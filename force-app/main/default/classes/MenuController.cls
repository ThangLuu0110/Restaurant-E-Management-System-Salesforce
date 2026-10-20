public with sharing class MenuController {
    
    @AuraEnabled(cacheable=true)
    public static List<Menu_Item__c> getMenuItems(String category) {
        return [
            SELECT Id, Name, Category__c, Price__c, Description__c,
                   Dietary_Tags__c, Prep_Time_Minute__c, Image_URL__c
            FROM Menu_Item__c
            LIMIT 200
        ];
    }
}