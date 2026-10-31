@IsTest
private class OrderServiceTest {
  @TestSetup
  static void setupData() {
    insert new Table__c(Seating_Capacity__c = 4, Status__c = 'Available');

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

  private static Id getTableId() {
    return [SELECT Id FROM Table__c LIMIT 1].Id;
  }

  private static Id getMenuItemId(String name) {
    return [SELECT Id FROM Menu_Item__c WHERE Name = :name LIMIT 1].Id;
  }

  private static OrderService.OrderItemWrapper buildItem(
    Id menuItemId,
    Decimal quantity,
    String note
  ) {
    OrderService.OrderItemWrapper item = new OrderService.OrderItemWrapper();
    item.menuItemId = menuItemId;
    item.quantity = quantity;
    item.specialInstructions = note;
    return item;
  }

  private static void assertNothingInserted() {
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Order_Request__c],
      'Không được tạo Order_Request__c khi đơn bị từ chối'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Order_Item__c],
      'Không được tạo Order_Item__c khi đơn bị từ chối'
    );
  }

  // ---------- Happy path ----------

  @IsTest
  static void placeOrder_allItemsAvailable_createsOrderAndItems() {
    Id tableId = getTableId();
    Id phoId = getMenuItemId('Pho Bo');
    Id traDaId = getMenuItemId('Tra Da');

    List<OrderService.OrderItemWrapper> items = new List<OrderService.OrderItemWrapper>{
      buildItem(phoId, 2, 'Không hành'),
      buildItem(traDaId, 1, null)
    };

    Datetime beforeCall = System.now();
    Test.startTest();
    OrderService.placeOrder(tableId, items);
    Test.stopTest();

    List<Order_Request__c> orders = [
      SELECT Id, Table__c, Status__c, Order_Time__c
      FROM Order_Request__c
    ];
    Assert.areEqual(1, orders.size(), 'Phải tạo đúng 1 Order_Request__c');
    Order_Request__c order = orders[0];
    Assert.areEqual(tableId, order.Table__c, 'Order phải gắn với đúng bàn');
    Assert.areEqual(
      'Placed',
      order.Status__c,
      'Status của Order phải là Placed'
    );
    Assert.isNotNull(order.Order_Time__c, 'Order_Time__c phải được gán');
    Assert.isTrue(
      order.Order_Time__c >= beforeCall.addSeconds(-1),
      'Order_Time__c phải là thời điểm đặt món'
    );

    Map<Id, Order_Item__c> itemsByMenu = new Map<Id, Order_Item__c>();
    for (Order_Item__c oi : [
      SELECT
        Order__c,
        Menu_Item__c,
        Quantity__c,
        Special_Instructions__c,
        Status__c
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

    Order_Item__c traDa = itemsByMenu.get(traDaId);
    Assert.areEqual(
      order.Id,
      traDa.Order__c,
      'Order_Item__c phải thuộc Order vừa tạo'
    );
    Assert.areEqual(1, traDa.Quantity__c, 'Số lượng phải khớp');
    Assert.isNull(
      traDa.Special_Instructions__c,
      'Ghi chú rỗng phải giữ nguyên null'
    );
    Assert.areEqual(
      'Pending',
      traDa.Status__c,
      'Status của Order_Item__c phải là Pending'
    );
  }

  @IsTest
  static void placeOrder_sameMenuItemTwice_createsSeparateOrderItems() {
    Id phoId = getMenuItemId('Pho Bo');

    Test.startTest();
    OrderService.placeOrder(
      getTableId(),
      new List<OrderService.OrderItemWrapper>{
        buildItem(phoId, 1, 'Tô nhỏ'),
        buildItem(phoId, 1, 'Tô lớn')
      }
    );
    Test.stopTest();

    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Order_Request__c],
      'Phải tạo đúng 1 Order_Request__c'
    );
    Assert.areEqual(
      2,
      [SELECT COUNT() FROM Order_Item__c WHERE Menu_Item__c = :phoId],
      'Mỗi dòng trong giỏ phải thành 1 Order_Item__c riêng, kể cả khi trùng món'
    );
  }

  // ---------- Error paths ----------

  @IsTest
  static void placeOrder_unavailableItem_throwsAndInsertsNothing() {
    List<OrderService.OrderItemWrapper> items = new List<OrderService.OrderItemWrapper>{
      buildItem(getMenuItemId('Che Khuc'), 1, null)
    };

    Boolean thrown = false;
    Test.startTest();
    try {
      OrderService.placeOrder(getTableId(), items);
    } catch (AuraHandledException e) {
      thrown = true;
    }
    Test.stopTest();

    Assert.isTrue(thrown, 'Phải ném AuraHandledException khi món đã hết');
    assertNothingInserted();
  }

  @IsTest
  static void placeOrder_mixOfAvailableAndUnavailable_throwsAndInsertsNothing() {
    List<OrderService.OrderItemWrapper> items = new List<OrderService.OrderItemWrapper>{
      buildItem(getMenuItemId('Pho Bo'), 1, null),
      buildItem(getMenuItemId('Che Khuc'), 1, null)
    };

    Boolean thrown = false;
    Test.startTest();
    try {
      OrderService.placeOrder(getTableId(), items);
    } catch (AuraHandledException e) {
      thrown = true;
    }
    Test.stopTest();

    Assert.isTrue(thrown, 'Chỉ cần 1 món hết là phải từ chối cả đơn');
    assertNothingInserted();
  }

  @IsTest
  static void placeOrder_menuItemNotFound_throwsAndInsertsNothing() {
    // Tạo rồi xoá để có một Id hợp lệ nhưng không còn tồn tại
    Menu_Item__c deleted = new Menu_Item__c(
      Name = 'Mon Da Xoa',
      Price__c = 1000,
      Is_Available__c = true
    );
    insert deleted;
    Id deletedId = deleted.Id;
    delete deleted;

    Boolean thrown = false;
    Test.startTest();
    try {
      OrderService.placeOrder(
        getTableId(),
        new List<OrderService.OrderItemWrapper>{ buildItem(deletedId, 1, null) }
      );
    } catch (AuraHandledException e) {
      thrown = true;
    }
    Test.stopTest();

    Assert.isTrue(
      thrown,
      'Phải ném AuraHandledException khi món không tồn tại'
    );
    assertNothingInserted();
  }
}
