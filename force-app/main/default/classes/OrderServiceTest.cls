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
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Order_Error_Log__c],
      'Đơn bị từ chối ngay tại OrderService thì không publish event, không có log'
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
    // Chưa deliver event thì chưa có đơn nào được tạo
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Order_Request__c],
      'Đơn chỉ được tạo khi Order_Placed__e được xử lý'
    );
    Test.stopTest(); // deliver Order_Placed__e -> OrderPlacedEventTrigger

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

  @IsTest
  static void placeOrder_trimsNoteAndConvertsBlankToNull() {
    Id phoId = getMenuItemId('Pho Bo');
    Id traDaId = getMenuItemId('Tra Da');

    Test.startTest();
    OrderService.placeOrder(
      getTableId(),
      new List<OrderService.OrderItemWrapper>{
        buildItem(phoId, 1, '  Ít cay  '),
        buildItem(traDaId, 1, '   ')
      }
    );
    Test.stopTest();

    Assert.areEqual(
      'Ít cay',
      [
        SELECT Special_Instructions__c
        FROM Order_Item__c
        WHERE Menu_Item__c = :phoId
      ]
      .Special_Instructions__c,
      'Ghi chú phải được bỏ khoảng trắng thừa'
    );
    Assert.isNull(
      [
        SELECT Special_Instructions__c
        FROM Order_Item__c
        WHERE Menu_Item__c = :traDaId
      ]
      .Special_Instructions__c,
      'Ghi chú chỉ có khoảng trắng phải lưu là null'
    );
  }

  // ---------- Validate input ----------

  private static void assertRejected(
    Id tableId,
    List<OrderService.OrderItemWrapper> items,
    String expectedMessage
  ) {
    String actualMessage;
    try {
      OrderService.placeOrder(tableId, items);
    } catch (AuraHandledException e) {
      actualMessage = e.getMessage();
    }
    Assert.areEqual(expectedMessage, actualMessage);
    assertNothingInserted();
  }

  @IsTest
  static void placeOrder_missingTable_throws() {
    assertRejected(
      null,
      new List<OrderService.OrderItemWrapper>{
        buildItem(getMenuItemId('Pho Bo'), 1, null)
      },
      OrderService.ERROR_MISSING_TABLE
    );
  }

  @IsTest
  static void placeOrder_emptyOrNullItems_throws() {
    assertRejected(
      getTableId(),
      new List<OrderService.OrderItemWrapper>(),
      OrderService.ERROR_EMPTY_ORDER
    );
    assertRejected(getTableId(), null, OrderService.ERROR_EMPTY_ORDER);
  }

  @IsTest
  static void placeOrder_invalidQuantity_throws() {
    Id phoId = getMenuItemId('Pho Bo');
    assertRejected(
      getTableId(),
      new List<OrderService.OrderItemWrapper>{ buildItem(phoId, 0, null) },
      OrderService.ERROR_INVALID_QUANTITY
    );
    assertRejected(
      getTableId(),
      new List<OrderService.OrderItemWrapper>{ buildItem(phoId, null, null) },
      OrderService.ERROR_INVALID_QUANTITY
    );
  }

  // ---------- addNewItem: gọi thêm món ----------

  /** Tạo đơn với 1 món Pho Bo, gắn vào Current_Order__c của bàn. */
  private static Order_Request__c createCurrentOrder(String status) {
    Id tableId = getTableId();
    Order_Request__c order = new Order_Request__c(
      Name = 'Existing Order',
      Table__c = tableId,
      Status__c = status
    );
    insert order;
    insert new Order_Item__c(
      Order__c = order.Id,
      Menu_Item__c = getMenuItemId('Pho Bo'),
      Quantity__c = 1
    );
    update new Table__c(Id = tableId, Current_Order__c = order.Id);
    return order;
  }

  private static String addNewItemError(
    Id tableId,
    List<OrderService.OrderItemWrapper> items
  ) {
    String message;
    try {
      OrderService.addNewItem(tableId, items);
    } catch (AuraHandledException e) {
      message = e.getMessage();
    }
    return message;
  }

  /** Đơn bị từ chối tại OrderService: không có đơn/món mới, không có log. */
  private static void assertOrderUnchanged(Id orderId) {
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Order_Request__c],
      'Không được tạo Order_Request__c mới'
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Order_Item__c WHERE Order__c = :orderId],
      'Không được thêm món vào đơn'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Order_Error_Log__c],
      'Bị từ chối tại OrderService thì không publish event, không có log'
    );
  }

  @IsTest
  static void addNewItem_activeOrder_addsItemsToExistingOrder() {
    Order_Request__c order = createCurrentOrder('Preparing');
    Id tableId = getTableId();
    Id traDaId = getMenuItemId('Tra Da');

    Test.startTest();
    OrderService.addNewItem(
      tableId,
      new List<OrderService.OrderItemWrapper>{
        buildItem(traDaId, 2, '  Ít đá  ')
      }
    );
    Test.stopTest(); // deliver Order_Placed__e

    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Order_Request__c],
      'Gọi thêm không được tạo Order_Request__c mới'
    );
    List<Order_Item__c> added = [
      SELECT Order__c, Quantity__c, Special_Instructions__c, Status__c
      FROM Order_Item__c
      WHERE Menu_Item__c = :traDaId
    ];
    Assert.areEqual(1, added.size(), 'Phải thêm đúng 1 Order_Item__c');
    Assert.areEqual(
      order.Id,
      added[0].Order__c,
      'Món gọi thêm phải thuộc đơn hiện tại của bàn'
    );
    Assert.areEqual(2, added[0].Quantity__c, 'Số lượng phải khớp');
    Assert.areEqual(
      'Ít đá',
      added[0].Special_Instructions__c,
      'Ghi chú phải được chuẩn hoá'
    );
    Assert.areEqual('Pending', added[0].Status__c, 'Món mới phải là Pending');
    Assert.areEqual(
      2,
      [SELECT COUNT() FROM Order_Item__c WHERE Order__c = :order.Id],
      'Món cũ phải được giữ nguyên'
    );
    Assert.areEqual(
      order.Id,
      [SELECT Current_Order__c FROM Table__c WHERE Id = :tableId]
      .Current_Order__c,
      'Current_Order__c của bàn không đổi'
    );
  }

  @IsTest
  static void addNewItem_servedOrder_isAllowed() {
    Order_Request__c order = createCurrentOrder('Served');

    Test.startTest();
    OrderService.addNewItem(
      getTableId(),
      new List<OrderService.OrderItemWrapper>{
        buildItem(getMenuItemId('Tra Da'), 1, null)
      }
    );
    Test.stopTest();

    Assert.areEqual(
      2,
      [SELECT COUNT() FROM Order_Item__c WHERE Order__c = :order.Id],
      'Đơn chưa Paid/Canceled thì vẫn được gọi thêm'
    );
  }

  @IsTest
  static void addNewItem_paidOrder_throws() {
    Order_Request__c order = createCurrentOrder('Paid');

    Test.startTest();
    String message = addNewItemError(
      getTableId(),
      new List<OrderService.OrderItemWrapper>{
        buildItem(getMenuItemId('Tra Da'), 1, null)
      }
    );
    Test.stopTest();

    Assert.areEqual(OrderService.ERROR_ORDER_CLOSED, message);
    assertOrderUnchanged(order.Id);
  }

  @IsTest
  static void addNewItem_canceledOrder_throws() {
    Order_Request__c order = createCurrentOrder('Canceled');

    Test.startTest();
    String message = addNewItemError(
      getTableId(),
      new List<OrderService.OrderItemWrapper>{
        buildItem(getMenuItemId('Tra Da'), 1, null)
      }
    );
    Test.stopTest();

    Assert.areEqual(OrderService.ERROR_ORDER_CLOSED, message);
    assertOrderUnchanged(order.Id);
  }

  @IsTest
  static void addNewItem_noCurrentOrder_throws() {
    Test.startTest();
    String message = addNewItemError(
      getTableId(),
      new List<OrderService.OrderItemWrapper>{
        buildItem(getMenuItemId('Tra Da'), 1, null)
      }
    );
    Test.stopTest();

    Assert.areEqual(OrderService.ERROR_NO_CURRENT_ORDER, message);
    assertNothingInserted();
  }

  @IsTest
  static void addNewItem_unavailableItem_throws() {
    Order_Request__c order = createCurrentOrder('Placed');

    Test.startTest();
    String message = addNewItemError(
      getTableId(),
      new List<OrderService.OrderItemWrapper>{
        buildItem(getMenuItemId('Che Khuc'), 1, null)
      }
    );
    Test.stopTest();

    Assert.isNotNull(message, 'Phải báo lỗi khi món đã hết');
    Assert.isTrue(message.contains('Che Khuc'), 'Lỗi phải nêu tên món');
    assertOrderUnchanged(order.Id);
  }

  @IsTest
  static void addNewItem_invalidInput_throws() {
    Order_Request__c order = createCurrentOrder('Placed');
    Id tableId = getTableId();
    Id phoId = getMenuItemId('Pho Bo');

    Test.startTest();
    String missingTable = addNewItemError(
      null,
      new List<OrderService.OrderItemWrapper>{ buildItem(phoId, 1, null) }
    );
    String emptyItems = addNewItemError(tableId, null);
    String badQuantity = addNewItemError(
      tableId,
      new List<OrderService.OrderItemWrapper>{ buildItem(phoId, 0, null) }
    );
    Test.stopTest();

    Assert.areEqual(OrderService.ERROR_MISSING_TABLE, missingTable);
    Assert.areEqual(OrderService.ERROR_EMPTY_ORDER, emptyItems);
    Assert.areEqual(OrderService.ERROR_INVALID_QUANTITY, badQuantity);
    assertOrderUnchanged(order.Id);
  }
}
