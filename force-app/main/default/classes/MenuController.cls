public with sharing class MenuController {
  @AuraEnabled(cacheable=true)
  public static List<Menu_Item__c> getMenuItems() {
    return [
      SELECT
        Id,
        Name,
        Category__c,
        Price__c,
        Description__c,
        Dietary_Tags__c,
        Prep_Time_Minute__c,
        Image_URL__c
      FROM Menu_Item__c
      WHERE Is_Available__c = TRUE
      WITH USER_MODE
      ORDER BY Category__c, Name
      LIMIT 200
    ];
  }

  @AuraEnabled(cacheable=true)
  public static List<String> getCategoryOptions() {
    List<String> options = new List<String>();
    Schema.DescribeFieldResult fieldResult = Menu_Item__c.Category__c.getDescribe();
    for (Schema.PicklistEntry entry : fieldResult.getPicklistValues()) {
      if (entry.isActive()) {
        options.add(entry.getValue());
      }
    }
    return options;
  }
}
