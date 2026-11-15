public with sharing class OrderService {
  @TestVisible
  private static final String ERROR_MISSING_TABLE = 'Không xác định được bàn, vui lòng quét lại mã QR.';
  @TestVisible
  private static final String ERROR_EMPTY_ORDER = 'Giỏ hàng đang trống.';
  @TestVisible
  private static final String ERROR_INVALID_QUANTITY = 'Số lượng mỗi món phải lớn hơn 0.';

  // Phải dùng property { get; set; }: dữ liệu gửi từ LWC chỉ được gán vào
  // property có @AuraEnabled, biến thường sẽ luôn nhận null.
  public class OrderItemWrapper {
    @AuraEnabled
    public Id menuItemId { get; set; }
    @AuraEnabled
    public Decimal quantity { get; set; }
    @AuraEnabled
    public String specialInstructions { get; set; }
  }

  /**
   * Tạo 1 Order_Request__c (Status = Placed) cùng các Order_Item__c cho bàn.
   * Trả về Id của Order_Request__c vừa tạo.
   */
  @AuraEnabled
  public static Id placeOrder(Id tableId, List<OrderItemWrapper> orderItems) {
    validateInput(tableId, orderItems);

    /**
     * Tập hợp ID các món ăn trong menu được gọi
     * Kiểm tra xem có món không khả thi không, nếu có dừng việc gọi món
     */

    Set<Id> menuItemIds = new Set<Id>();
    for (OrderItemWrapper orderItem : orderItems) {
      menuItemIds.add(orderItem.menuItemId);
    }

    OrderDataAccess dataAccess = new OrderDataAccess();
    Map<Id, Menu_Item__c> menuById = dataAccess.findMenuItems(menuItemIds);

    for (OrderItemWrapper orderItem : orderItems) {
      Menu_Item__c menuItem = menuById.get(orderItem.menuItemId);
      if (menuItem == null || !menuItem.Is_Available__c) {
        throw buildError(
          'Món "' +
            (menuItem != null ? menuItem.Name : orderItem.menuItemId) +
            '" hiện đã hết, vui lòng bỏ khỏi giỏ và gửi lại đơn.'
        );
      }
    }

    /**
     * Thực hiện tạo Order_Request__c với Status__c = 'Placed'
     * Tạo danh sách các Order_Item__c dựa trên các món được đặt
     */

    Order_Request__c newOrderRequest = new Order_Request__c(
      Table__c = tableId,
      Status__c = 'Placed',
      Order_Time__c = System.now()
    );

    List<Order_Item__c> newOrderedItems = new List<Order_Item__c>();
    for (OrderItemWrapper orderItem : orderItems) {
      newOrderedItems.add(
        new Order_Item__c(
          Menu_Item__c = orderItem.menuItemId,
          Quantity__c = orderItem.quantity,
          Special_Instructions__c = String.isBlank(
              orderItem.specialInstructions
            )
            ? null
            : orderItem.specialInstructions.trim(),
          Status__c = 'Pending'
        )
      );
    }

    dataAccess.insertOrder(newOrderRequest, newOrderedItems);
    return newOrderRequest.Id;
  }

  private static void validateInput(
    Id tableId,
    List<OrderItemWrapper> orderItems
  ) {
    if (tableId == null) {
      throw buildError(ERROR_MISSING_TABLE);
    }
    if (orderItems == null || orderItems.isEmpty()) {
      throw buildError(ERROR_EMPTY_ORDER);
    }
    for (OrderItemWrapper orderItem : orderItems) {
      if (
        orderItem == null ||
        orderItem.quantity == null ||
        orderItem.quantity <= 0
      ) {
        throw buildError(ERROR_INVALID_QUANTITY);
      }
    }
  }

  // setMessage để getMessage() trả về đúng nội dung (Apex test và log đọc được)
  private static AuraHandledException buildError(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    return error;
  }

  /**
   * Truy cập dữ liệu cho đặt hàng, chạy without sharing:
   * - findMenuItems: tình trạng món được quyết định bởi Is_Available__c,
   *   không phụ thuộc vào việc guest có được share bản ghi hay không.
   * - insertOrder: bản ghi guest tạo ra thuộc về owner mặc định của site nên
   *   guest không có quyền sửa Order_Request__c vừa tạo. Order_Item__c là
   *   Master-Detail nên cần quyền đó để insert.
   * Việc kiểm tra đầu vào và tình trạng món vẫn nằm ở class ngoài.
   */
  private without sharing class OrderDataAccess {
    Map<Id, Menu_Item__c> findMenuItems(Set<Id> menuItemIds) {
      return new Map<Id, Menu_Item__c>(
        [
          SELECT Id, Name, Price__c, Is_Available__c
          FROM Menu_Item__c
          WHERE Id IN :menuItemIds
        ]
      );
    }

    void insertOrder(Order_Request__c order, List<Order_Item__c> items) {
      insert order;
      for (Order_Item__c item : items) {
        item.Order__c = order.Id;
      }
      insert items;
    }
  }
}
