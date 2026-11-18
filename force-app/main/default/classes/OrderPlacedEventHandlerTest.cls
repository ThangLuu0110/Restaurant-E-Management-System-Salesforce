@IsTest
private class OrderPlacedEventHandlerTest {
  @TestSetup
  static void setupData() {
    insert new List<Table__c>{
      new Table__c(Seating_Capacity__c = 4, Status__c = 'Available'),
      new Table__c(Seating_Capacity__c = 2, Status__c = 'Available')
    };

    insert new List<Menu_Item__c>{
      new Menu_Item__c(
        Name = 'Pho Bo',
        Price__c = 50000,
        Is_Available__c = true,
        Category__c = 'Main Course'
      ),
      new Menu_Item__c(
        Name = 'Tra Da',
        Price__c = 5000,
        Is_Available__c = true,
        Category__c = 'Beverage'
      ),
      new Menu_Item__c(
        Name = 'Che Khuc',
        Price__c = 20000,
        Is_Available__c = false,
        Category__c = 'Dessert'
      )
    };
  }

  // ---------- Helpers ----------

  private static List<Id> getTableIds() {
    List<Id> ids = new List<Id>();
    for (Table__c table : [
      SELECT Id
      FROM Table__c
      ORDER BY Seating_Capacity__c DESC
    ]) {
      ids.add(table.Id);
    }
    return ids;
  }

  private static Id getMenuItemId(String name) {
    return [SELECT Id FROM Menu_Item__c WHERE Name = :name LIMIT 1].Id;
  }

  private static Map<String, Object> item(
    Id menuItemId,
    Decimal quantity,
    String note
  ) {
    return new Map<String, Object>{
      'menuItemId' => menuItemId,
      'quantity' => quantity,
      'specialInstructions' => note
    };
  }

  private static Order_Placed__e buildEvent(
    String tableId,
    List<Object> items
  ) {
    return new Order_Placed__e(
      Table_Id__c = tableId,
      Items_JSON__c = JSON.serialize(items)
    );
  }

  private static void deliver(List<Order_Placed__e> events) {
    Test.startTest();
    List<Database.SaveResult> results = EventBus.publish(events);
    Test.stopTest();
    for (Database.SaveResult result : results) {
      Assert.isTrue(result.isSuccess(), 'Publish event phải thành công');
    }
  }

  private static void assertNoOrder() {
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Order_Request__c],
      'Không được tạo Order_Request__c'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Order_Item__c],
      'Không được tạo Order_Item__c'
    );
  }

  private static Order_Error_Log__c getSingleLog() {
    List<Order_Error_Log__c> logs = [
      SELECT Table_Id__c, Payload__c, Error_Message__c, Event_Replay_Id__c
      FROM Order_Error_Log__c
    ];
    Assert.areEqual(1, logs.size(), 'Phải ghi đúng 1 Order_Error_Log__c');
    return logs[0];
  }

  // ---------- Happy path ----------

  @IsTest
  static void validEvent_createsOrderAndItems() {
    Id tableId = getTableIds()[0];
    Id phoId = getMenuItemId('Pho Bo');
    Id traDaId = getMenuItemId('Tra Da');

    deliver(
      new List<Order_Placed__e>{
        buildEvent(
          tableId,
          new List<Object>{
            item(phoId, 2, 'Không hành'),
            item(traDaId, 1, null)
          }
        )
      }
    );

    Order_Request__c order = [
      SELECT Table__c, Status__c, Order_Time__c
      FROM Order_Request__c
    ];
    Assert.areEqual(tableId, order.Table__c, 'Order phải gắn với đúng bàn');
    Assert.areEqual(
      'Placed',
      order.Status__c,
      'Status của Order phải là Placed'
    );
    Assert.isNotNull(order.Order_Time__c, 'Order_Time__c phải được gán');

    Map<Id, Order_Item__c> itemsByMenu = new Map<Id, Order_Item__c>();
    for (Order_Item__c oi : [
      SELECT
        Order__c,
        Menu_Item__c,
        Quantity__c,
        Special_Instructions__c,
        Status__c,
        Line_Subtotal__c
      FROM Order_Item__c
    ]) {
      itemsByMenu.put(oi.Menu_Item__c, oi);
    }
    Assert.areEqual(2, itemsByMenu.size(), 'Phải tạo 2 Order_Item__c');
    Order_Item__c pho = itemsByMenu.get(phoId);
    Assert.areEqual(
      order.Id,
      pho.Order__c,
      'Order_Item__c phải thuộc Order vừa tạo'
    );
    Assert.areEqual(2, pho.Quantity__c, 'Số lượng phải khớp');
    Assert.areEqual(
      'Không hành',
      pho.Special_Instructions__c,
      'Ghi chú phải khớp'
    );
    Assert.areEqual(
      'Pending',
      pho.Status__c,
      'Status của Order_Item__c phải là Pending'
    );
    Assert.areEqual(
      100000,
      pho.Line_Subtotal__c,
      'OrderItemTrigger vẫn phải tính thành tiền'
    );
    Assert.isNull(
      itemsByMenu.get(traDaId).Special_Instructions__c,
      'Ghi chú rỗng phải là null'
    );

    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Order_Error_Log__c],
      'Đơn hợp lệ thì không có log'
    );

    Assert.areEqual(
      order.Id,
      [SELECT Current_Order__c FROM Table__c WHERE Id = :tableId]
      .Current_Order__c,
      'Table__c.Current_Order__c phải trỏ về Order vừa tạo'
    );
  }

  @IsTest
  static void multipleEvents_createsOneOrderPerEvent() {
    List<Id> tableIds = getTableIds();
    Id phoId = getMenuItemId('Pho Bo');

    deliver(
      new List<Order_Placed__e>{
        buildEvent(tableIds[0], new List<Object>{ item(phoId, 1, null) }),
        buildEvent(tableIds[1], new List<Object>{ item(phoId, 3, null) })
      }
    );

    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Order_Request__c WHERE Table__c = :tableIds[0]]
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Order_Request__c WHERE Table__c = :tableIds[1]]
    );
    Assert.areEqual(
      2,
      [SELECT COUNT() FROM Order_Item__c],
      'Mỗi đơn có 1 Order_Item__c'
    );
  }

  @IsTest
  static void oneInvalidEvent_doesNotBlockOthers() {
    List<Id> tableIds = getTableIds();

    deliver(
      new List<Order_Placed__e>{
        buildEvent(
          tableIds[0],
          new List<Object>{ item(getMenuItemId('Pho Bo'), 1, null) }
        ),
        buildEvent(
          tableIds[1],
          new List<Object>{ item(getMenuItemId('Che Khuc'), 1, null) }
        )
      }
    );

    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Order_Request__c],
      'Chỉ đơn hợp lệ được tạo'
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Order_Request__c WHERE Table__c = :tableIds[0]]
    );
    Assert.areEqual(
      String.valueOf(tableIds[1]),
      getSingleLog().Table_Id__c,
      'Log phải thuộc đơn lỗi'
    );
  }

  // ---------- Error paths: không tạo đơn, chỉ ghi log ----------

  @IsTest
  static void unavailableItem_logsAndCreatesNothing() {
    Id tableId = getTableIds()[0];
    List<Object> items = new List<Object>{
      item(getMenuItemId('Pho Bo'), 1, null),
      item(getMenuItemId('Che Khuc'), 1, null)
    };

    deliver(new List<Order_Placed__e>{ buildEvent(tableId, items) });

    assertNoOrder();
    Order_Error_Log__c log = getSingleLog();
    Assert.areEqual(
      OrderPlacedEventHandler.ERROR_ITEM_UNAVAILABLE + 'Che Khuc',
      log.Error_Message__c,
      'Log phải ghi rõ món đã hết'
    );
    Assert.areEqual(
      String.valueOf(tableId),
      log.Table_Id__c,
      'Log phải lưu Table Id'
    );
    Assert.areEqual(
      JSON.serialize(items),
      log.Payload__c,
      'Log phải lưu payload gốc'
    );
    Assert.isNotNull(log.Event_Replay_Id__c, 'Log phải lưu ReplayId của event');
  }

  @IsTest
  static void tableNotFound_logsAndCreatesNothing() {
    Table__c deleted = new Table__c(
      Seating_Capacity__c = 6,
      Status__c = 'Available'
    );
    insert deleted;
    Id deletedId = deleted.Id;
    delete deleted;

    deliver(
      new List<Order_Placed__e>{
        buildEvent(
          deletedId,
          new List<Object>{ item(getMenuItemId('Pho Bo'), 1, null) }
        )
      }
    );

    assertNoOrder();
    Assert.areEqual(
      OrderPlacedEventHandler.ERROR_TABLE_NOT_FOUND,
      getSingleLog().Error_Message__c
    );
  }

  @IsTest
  static void emptyItems_logsAndCreatesNothing() {
    deliver(
      new List<Order_Placed__e>{
        buildEvent(getTableIds()[0], new List<Object>())
      }
    );

    assertNoOrder();
    Assert.areEqual(
      OrderPlacedEventHandler.ERROR_EMPTY_ORDER,
      getSingleLog().Error_Message__c
    );
  }

  @IsTest
  static void invalidQuantity_logsAndCreatesNothing() {
    deliver(
      new List<Order_Placed__e>{
        buildEvent(
          getTableIds()[0],
          new List<Object>{ item(getMenuItemId('Pho Bo'), 0, null) }
        )
      }
    );

    assertNoOrder();
    Assert.areEqual(
      OrderPlacedEventHandler.ERROR_INVALID_QUANTITY,
      getSingleLog().Error_Message__c
    );
  }

  @IsTest
  static void invalidPayload_logsAndCreatesNothing() {
    deliver(
      new List<Order_Placed__e>{
        new Order_Placed__e(
          Table_Id__c = getTableIds()[0],
          Items_JSON__c = 'không phải JSON'
        ),
        new Order_Placed__e(Table_Id__c = 'abc', Items_JSON__c = '[]')
      }
    );

    assertNoOrder();
    List<Order_Error_Log__c> logs = [
      SELECT Error_Message__c
      FROM Order_Error_Log__c
    ];
    Assert.areEqual(2, logs.size(), 'Mỗi event lỗi phải có 1 log');
    for (Order_Error_Log__c log : logs) {
      Assert.isTrue(
        log.Error_Message__c.startsWith(
          OrderPlacedEventHandler.ERROR_INVALID_PAYLOAD
        ),
        'Log phải ghi lỗi đọc dữ liệu: ' + log.Error_Message__c
      );
    }
  }

  @IsTest
  static void itemInsertFails_deletesOrderAndLogs() {
    // Ghi chú dài hơn 255 ký tự -> Order_Item__c insert lỗi STRING_TOO_LONG
    String tooLongNote = 'x'.repeat(300);

    deliver(
      new List<Order_Placed__e>{
        buildEvent(
          getTableIds()[0],
          new List<Object>{
            item(getMenuItemId('Pho Bo'), 1, null),
            item(getMenuItemId('Tra Da'), 1, tooLongNote)
          }
        )
      }
    );

    assertNoOrder();
    Assert.isTrue(
      getSingleLog()
        .Error_Message__c.startsWith(OrderPlacedEventHandler.ERROR_INSERT_ITEM),
      'Log phải ghi lỗi tạo Order_Item__c'
    );
  }
}
