@IsTest
private class OrderItemTriggerHandlerTest {
  private static final Decimal PHO_PRICE = 55000;

  @TestSetup
  static void setup() {
    TestDataFactory.createOrderWithTable();
    TestDataFactory.createMenuItem('Phở bò tái', PHO_PRICE, true);
  }

  private static Order_Request__c getOrder() {
    return [SELECT Id FROM Order_Request__c LIMIT 1];
  }

  private static Menu_Item__c getMenuItem() {
    return [SELECT Id FROM Menu_Item__c LIMIT 1];
  }

  @IsTest
  static void insertValidQuantity_calculatesLineSubtotal() {
    Order_Item__c item = TestDataFactory.buildOrderItems(
      getOrder().Id,
      getMenuItem().Id,
      3,
      1
    )[0];

    Test.startTest();
    insert item;
    Test.stopTest();

    Order_Item__c saved = [
      SELECT Line_Subtotal__c
      FROM Order_Item__c
      WHERE Id = :item.Id
    ];
    Assert.areEqual(
      3 * PHO_PRICE,
      saved.Line_Subtotal__c,
      'Line_Subtotal__c phải = Quantity x Price'
    );
  }

  @IsTest
  static void insertWithoutStatus_defaultsToPending() {
    Order_Item__c item = TestDataFactory.buildOrderItems(
      getOrder().Id,
      getMenuItem().Id,
      1,
      1
    )[0];

    Test.startTest();
    insert item;
    Test.stopTest();

    Order_Item__c saved = [
      SELECT Status__c
      FROM Order_Item__c
      WHERE Id = :item.Id
    ];
    Assert.areEqual(
      'Pending',
      saved.Status__c,
      'Status__c trống phải mặc định là Pending'
    );
  }

  @IsTest
  static void beforeInsert_nullStatus_setsPendingInMemory() {
    // Gọi thẳng handler để chắc chắn nhánh Status__c == null được kiểm tra,
    // không phụ thuộc vào giá trị default của picklist trong org
    Order_Item__c item = new Order_Item__c(Quantity__c = 1, Status__c = null);

    OrderItemTriggerHandler.beforeInsert(new List<Order_Item__c>{ item });

    Assert.areEqual(OrderItemTriggerHandler.STATUS_PENDING, item.Status__c);
    Assert.isNull(
      item.Line_Subtotal__c,
      'Không có Menu Item thì không tính tiền'
    );
  }

  @IsTest
  static void insertWithExistingStatus_keepsStatus() {
    Order_Item__c item = TestDataFactory.buildOrderItems(
      getOrder().Id,
      getMenuItem().Id,
      1,
      1
    )[0];
    item.Status__c = 'Accepted';

    Test.startTest();
    insert item;
    Test.stopTest();

    Order_Item__c saved = [
      SELECT Status__c
      FROM Order_Item__c
      WHERE Id = :item.Id
    ];
    Assert.areEqual(
      'Accepted',
      saved.Status__c,
      'Status__c đã có thì không bị ghi đè'
    );
  }

  @IsTest
  static void insertZeroOrNullQuantity_isBlocked() {
    Id orderId = getOrder().Id;
    Id menuItemId = getMenuItem().Id;
    List<Order_Item__c> items = new List<Order_Item__c>{
      TestDataFactory.buildOrderItems(orderId, menuItemId, 0, 1)[0],
      TestDataFactory.buildOrderItems(orderId, menuItemId, null, 1)[0],
      TestDataFactory.buildOrderItems(orderId, menuItemId, -2, 1)[0],
      TestDataFactory.buildOrderItems(orderId, menuItemId, 2, 1)[0]
    };

    Test.startTest();
    List<Database.SaveResult> results = Database.insert(items, false);
    Test.stopTest();

    for (Integer i = 0; i < 3; i++) {
      Assert.isFalse(
        results[i].isSuccess(),
        'Record ' + i + ' có số lượng không hợp lệ phải bị chặn'
      );
      Assert.areEqual(
        OrderItemTriggerHandler.ERROR_INVALID_QUANTITY,
        results[i].getErrors()[0].getMessage(),
        'Sai message lỗi'
      );
    }
    // addError chỉ chặn record sai, record hợp lệ trong cùng batch vẫn được lưu
    Assert.isTrue(
      results[3].isSuccess(),
      'Record hợp lệ không được bị chặn theo'
    );
    Assert.areEqual(1, [SELECT COUNT() FROM Order_Item__c]);
  }

  @IsTest
  static void insertZeroQuantity_throwsDmlExceptionWhenAllOrNone() {
    Order_Item__c item = TestDataFactory.buildOrderItems(
      getOrder().Id,
      getMenuItem().Id,
      0,
      1
    )[0];

    Test.startTest();
    try {
      insert item;
      Assert.fail('Phải ném DmlException khi Quantity__c = 0');
    } catch (DmlException e) {
      Assert.isTrue(
        e.getMessage().contains(OrderItemTriggerHandler.ERROR_INVALID_QUANTITY)
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void bulkInsert_queryCountDoesNotGrowWithRecordCount() {
    Id orderId = getOrder().Id;
    Menu_Item__c secondMenuItem = TestDataFactory.createMenuItem(
      'Cà phê sữa đá',
      30000,
      true
    );
    List<Order_Item__c> single = TestDataFactory.buildOrderItems(
      orderId,
      getMenuItem().Id,
      1,
      1
    );
    // 200 record trộn 2 món khác nhau, đúng kích thước 1 batch trigger
    List<Order_Item__c> bulkItems = TestDataFactory.buildOrderItems(
      orderId,
      getMenuItem().Id,
      2,
      100
    );
    bulkItems.addAll(
      TestDataFactory.buildOrderItems(orderId, secondMenuItem.Id, 2, 100)
    );

    Test.startTest();
    Integer queriesBefore = Limits.getQueries();
    insert single;
    Integer singleQueries = Limits.getQueries() - queriesBefore;

    queriesBefore = Limits.getQueries();
    insert bulkItems;
    Integer bulkQueries = Limits.getQueries() - queriesBefore;
    Test.stopTest();

    // 1 SOQL lấy giá (before insert) + 1 SOQL tính Subtotal__c (after insert)
    Assert.areEqual(2, singleQueries, 'Trigger chỉ được dùng đúng 2 SOQL');
    Assert.areEqual(
      singleQueries,
      bulkQueries,
      'Số SOQL không được tăng theo số record'
    );

    for (Order_Item__c saved : [
      SELECT Line_Subtotal__c, Menu_Item__c
      FROM Order_Item__c
      WHERE Id IN :bulkItems
    ]) {
      Decimal expected = saved.Menu_Item__c == secondMenuItem.Id
        ? 2 * 30000
        : 2 * PHO_PRICE;
      Assert.areEqual(expected, saved.Line_Subtotal__c);
    }
    Assert.areEqual(
      PHO_PRICE + 100 * 2 * PHO_PRICE + 100 * 2 * 30000,
      getSubtotal(orderId),
      'Subtotal__c phải bằng tổng mọi dòng trong đơn'
    );
  }

  @IsTest
  static void insertMenuItemWithoutPrice_leavesSubtotalEmpty() {
    Menu_Item__c noPrice = TestDataFactory.createMenuItem(
      'Món chưa có giá',
      null,
      true
    );
    Order_Item__c item = TestDataFactory.buildOrderItems(
      getOrder().Id,
      noPrice.Id,
      2,
      1
    )[0];

    Test.startTest();
    insert item;
    Test.stopTest();

    Order_Item__c saved = [
      SELECT Line_Subtotal__c
      FROM Order_Item__c
      WHERE Id = :item.Id
    ];
    Assert.isNull(
      saved.Line_Subtotal__c,
      'Menu Item chưa có giá thì Line_Subtotal__c để trống'
    );
    Assert.areEqual(
      0,
      getSubtotal(getOrder().Id),
      'Dòng chưa có giá được tính là 0 trong Subtotal__c'
    );
  }

  // ---------- Subtotal__c của Order_Request__c ----------

  private static Decimal getSubtotal(Id orderId) {
    return [SELECT Subtotal__c FROM Order_Request__c WHERE Id = :orderId]
    .Subtotal__c;
  }

  private static Order_Item__c insertItem(Decimal quantity) {
    Order_Item__c item = TestDataFactory.buildOrderItems(
      getOrder().Id,
      getMenuItem().Id,
      quantity,
      1
    )[0];
    insert item;
    return item;
  }

  @IsTest
  static void insert_setsOrderSubtotal() {
    Test.startTest();
    insertItem(2);
    insertItem(1);
    Test.stopTest();

    Assert.areEqual(
      3 * PHO_PRICE,
      getSubtotal(getOrder().Id),
      'Subtotal__c phải cộng dồn mọi lần thêm món'
    );
  }

  @IsTest
  static void cancelItem_isExcludedFromSubtotal() {
    Order_Item__c kept = insertItem(2);
    Order_Item__c canceled = insertItem(1);

    Test.startTest();
    update new Order_Item__c(
      Id = canceled.Id,
      Status__c = OrderItemTriggerHandler.STATUS_CANCELED
    );
    Test.stopTest();

    Assert.areEqual(
      2 * PHO_PRICE,
      getSubtotal(getOrder().Id),
      'Món Canceled không được tính vào Subtotal__c'
    );
  }

  @IsTest
  static void quantityChange_recalculatesLineAndSubtotal() {
    Order_Item__c item = insertItem(1);

    Test.startTest();
    update new Order_Item__c(Id = item.Id, Quantity__c = 4);
    Test.stopTest();

    Assert.areEqual(
      4 * PHO_PRICE,
      [SELECT Line_Subtotal__c FROM Order_Item__c WHERE Id = :item.Id]
      .Line_Subtotal__c,
      'Đổi số lượng phải tính lại Line_Subtotal__c'
    );
    Assert.areEqual(4 * PHO_PRICE, getSubtotal(getOrder().Id));
  }

  @IsTest
  static void updateQuantityToZero_isBlocked() {
    Order_Item__c item = insertItem(1);

    Test.startTest();
    Database.SaveResult result = Database.update(
      new Order_Item__c(Id = item.Id, Quantity__c = 0),
      false
    );
    Test.stopTest();

    Assert.isFalse(result.isSuccess(), 'Không được sửa số lượng về 0');
    Assert.areEqual(
      OrderItemTriggerHandler.ERROR_INVALID_QUANTITY,
      result.getErrors()[0].getMessage()
    );
    Assert.areEqual(PHO_PRICE, getSubtotal(getOrder().Id));
  }

  @IsTest
  static void deleteAndUndelete_recalculatesSubtotal() {
    insertItem(2);
    Order_Item__c removed = insertItem(1);

    Test.startTest();
    delete removed;
    Decimal afterDelete = getSubtotal(getOrder().Id);
    undelete removed;
    Test.stopTest();

    Assert.areEqual(
      2 * PHO_PRICE,
      afterDelete,
      'Xoá món phải giảm Subtotal__c'
    );
    Assert.areEqual(
      3 * PHO_PRICE,
      getSubtotal(getOrder().Id),
      'Khôi phục món phải cộng lại vào Subtotal__c'
    );
  }

  @IsTest
  static void bulkUpdate_recalculatesSubtotalOfEachOrder() {
    Id firstOrderId = getOrder().Id;
    Order_Request__c secondOrder = TestDataFactory.createOrderWithTable();
    List<Order_Item__c> items = TestDataFactory.buildOrderItems(
      firstOrderId,
      getMenuItem().Id,
      1,
      100
    );
    items.addAll(
      TestDataFactory.buildOrderItems(secondOrder.Id, getMenuItem().Id, 1, 100)
    );
    insert items;

    Test.startTest();
    // Chỉ gửi field cần đổi: Order__c (Master-Detail) không cho phép sửa
    List<Order_Item__c> changes = new List<Order_Item__c>();
    for (Order_Item__c item : items) {
      changes.add(new Order_Item__c(Id = item.Id, Quantity__c = 2));
    }
    update changes;
    Test.stopTest();

    Assert.areEqual(200 * PHO_PRICE, getSubtotal(firstOrderId));
    Assert.areEqual(200 * PHO_PRICE, getSubtotal(secondOrder.Id));
  }
}
