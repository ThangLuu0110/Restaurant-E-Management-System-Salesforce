@IsTest
private class MenuControllerTest {
  @IsTest
  static void getMenuItems_returnsOnlyAvailableItems() {
    Menu_Item__c available = TestDataFactory.createMenuItem(
      'Pho Bo',
      50000,
      false
    );
    available.Is_Available__c = true;
    Menu_Item__c unavailable = TestDataFactory.createMenuItem(
      'Bun Cha',
      45000,
      false
    );
    unavailable.Is_Available__c = false;
    insert new List<Menu_Item__c>{ available, unavailable };

    Test.startTest();
    List<Menu_Item__c> result = MenuController.getMenuItems();
    Test.stopTest();

    Assert.areEqual(1, result.size(), 'Chỉ trả về món đang bán');
    Assert.areEqual(available.Id, result[0].Id);
  }

  @IsTest
  static void getCategoryOptions_returnsActivePicklistValues() {
    Integer activeCount = 0;
    for (
      Schema.PicklistEntry entry : Menu_Item__c.Category__c.getDescribe()
        .getPicklistValues()
    ) {
      if (entry.isActive()) {
        activeCount++;
      }
    }

    Test.startTest();
    List<String> options = MenuController.getCategoryOptions();
    Test.stopTest();

    Assert.areEqual(activeCount, options.size());
  }

  @IsTest
  static void getTableIdByNumber_returnsIdWhenTableExists() {
    Table__c table = TestDataFactory.createTable(true);
    // Name là Auto Number (Table-{00}) nên đọc lại giá trị thực tế sau khi insert
    String tableName = [SELECT Name FROM Table__c WHERE Id = :table.Id].Name;
    String tableNumber = tableName.substringAfter('Table-');

    Test.startTest();
    Id result = MenuController.getTableIdByNumber(tableNumber);
    Test.stopTest();

    Assert.areEqual(table.Id, result);
  }

  @IsTest
  static void getTableIdByNumber_trimsWhitespace() {
    Table__c table = TestDataFactory.createTable(true);
    String tableName = [SELECT Name FROM Table__c WHERE Id = :table.Id].Name;
    String tableNumber = tableName.substringAfter('Table-');

    Assert.areEqual(
      table.Id,
      MenuController.getTableIdByNumber(' ' + tableNumber + ' ')
    );
  }

  @IsTest
  static void getTableIdByNumber_returnsNullWhenTableNotFound() {
    TestDataFactory.createTable(true);

    Assert.isNull(MenuController.getTableIdByNumber('999'));
  }

  @IsTest
  static void getTableIdByNumber_returnsNullForInvalidInput() {
    TestDataFactory.createTable(true);

    Assert.isNull(MenuController.getTableIdByNumber(null));
    Assert.isNull(MenuController.getTableIdByNumber(''));
    Assert.isNull(MenuController.getTableIdByNumber('abc'));
    Assert.isNull(MenuController.getTableIdByNumber('01\' OR Name != \''));
    Assert.isNull(MenuController.getTableIdByNumber('12345678901'));
  }
}
