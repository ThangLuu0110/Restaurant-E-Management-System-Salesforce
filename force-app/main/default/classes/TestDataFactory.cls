/**
 * Factory tạo dữ liệu test dùng chung cho các test class.
 */
@IsTest
public class TestDataFactory {
  public static Table__c createTable(Boolean doInsert) {
    // Seating_Capacity__c là field bắt buộc
    Table__c table = new Table__c(Seating_Capacity__c = 4);
    if (doInsert) {
      insert table;
    }
    return table;
  }

  public static Order_Request__c createOrder(Id tableId, Boolean doInsert) {
    Order_Request__c orderRecord = new Order_Request__c(
      Name = 'Test Order',
      Table__c = tableId
    );
    if (doInsert) {
      insert orderRecord;
    }
    return orderRecord;
  }

  /** Tạo sẵn Table + Order_Request__c (parent bắt buộc của Order_Item__c). */
  public static Order_Request__c createOrderWithTable() {
    Table__c table = createTable(true);
    return createOrder(table.Id, true);
  }

  public static Menu_Item__c createMenuItem(
    String name,
    Decimal price,
    Boolean doInsert
  ) {
    Menu_Item__c menuItem = new Menu_Item__c(Name = name, Price__c = price);
    if (doInsert) {
      insert menuItem;
    }
    return menuItem;
  }

  /** Chỉ build record, không insert, để test tự quyết cách DML. */
  public static List<Order_Item__c> buildOrderItems(
    Id orderId,
    Id menuItemId,
    Decimal quantity,
    Integer count
  ) {
    List<Order_Item__c> items = new List<Order_Item__c>();
    for (Integer i = 0; i < count; i++) {
      items.add(
        new Order_Item__c(
          Order__c = orderId,
          Menu_Item__c = menuItemId,
          Quantity__c = quantity
        )
      );
    }
    return items;
  }
}
