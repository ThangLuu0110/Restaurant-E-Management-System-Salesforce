public with sharing class MenuController {
  // Name của Table__c là Auto Number với format Table-{00}
  private static final String TABLE_NAME_PREFIX = 'Table-';

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

  /**
   * Tìm Id của Table__c theo số bàn trên URL (?tableId=03 -> Name = 'Table-03').
   * Trả về null nếu số bàn không hợp lệ hoặc không tồn tại.
   */
  @AuraEnabled(cacheable=true)
  public static Id getTableIdByNumber(String tableNumber) {
    if (String.isBlank(tableNumber)) {
      return null;
    }
    String trimmed = tableNumber.trim();
    if (!Pattern.matches('\\d{1,10}', trimmed)) {
      return null;
    }

    String tableName = TABLE_NAME_PREFIX + trimmed;
    List<Table__c> tables = [
      SELECT Id
      FROM Table__c
      WHERE Name = :tableName
      WITH USER_MODE
      LIMIT 1
    ];
    return tables.isEmpty() ? null : tables[0].Id;
  }
}
