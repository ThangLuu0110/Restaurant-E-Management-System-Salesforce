public with sharing class OrderService {
  @TestVisible
  private static final String ERROR_MISSING_TABLE = 'Không xác định được bàn, vui lòng quét lại mã QR.';
  @TestVisible
  private static final String ERROR_EMPTY_ORDER = 'Giỏ hàng đang trống.';
  @TestVisible
  private static final String ERROR_INVALID_QUANTITY = 'Số lượng mỗi món phải lớn hơn 0.';
  @TestVisible
  private static final String ERROR_PUBLISH_FAILED = 'Không gửi được đơn, vui lòng thử lại.';

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
   * Kiểm tra đơn rồi publish Order_Placed__e. Việc tạo Order_Request__c và
   * Order_Item__c do OrderPlacedEventHandler thực hiện (chạy bằng Automated
   * Process user), vì guest không tạo được bản ghi con Master-Detail.
   * Các lỗi phát hiện được ở đây (bàn, giỏ trống, số lượng, món đã hết) được
   * báo ngay cho khách.
   *
   * Dùng cho cả lần đặt đầu tiên và các lần gọi thêm: nếu bàn đang có đơn
   * chưa Paid/Canceled, handler thêm món vào đơn đó thay vì tạo đơn mới.
   * Việc chọn đơn được quyết định lúc xử lý event để khách gửi nhiều lần liên
   * tiếp vẫn chỉ có 1 đơn.
   */
  @AuraEnabled
  public static void placeOrder(Id tableId, List<OrderItemWrapper> orderItems) {
    validateInput(tableId, orderItems);

    /**
     * Tập hợp ID các món ăn trong menu được gọi
     * Kiểm tra xem có món không khả thi không, nếu có dừng việc gọi món
     */

    Set<Id> menuItemIds = new Set<Id>();
    for (OrderItemWrapper orderItem : orderItems) {
      menuItemIds.add(orderItem.menuItemId);
    }

    Map<Id, Menu_Item__c> menuById = new OrderDataAccess()
      .findMenuItems(menuItemIds);

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

    // Chuẩn hoá ghi chú trước khi gửi: bỏ khoảng trắng thừa, rỗng thành null
    for (OrderItemWrapper orderItem : orderItems) {
      orderItem.specialInstructions = String.isBlank(
          orderItem.specialInstructions
        )
        ? null
        : orderItem.specialInstructions.trim();
    }

    Database.SaveResult result = EventBus.publish(
      new Order_Placed__e(
        Table_Id__c = tableId,
        Items_JSON__c = JSON.serialize(orderItems)
      )
    );
    if (!result.isSuccess()) {
      throw buildError(ERROR_PUBLISH_FAILED);
    }
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
   * Đọc món without sharing: tình trạng món được quyết định bởi
   * Is_Available__c, không phụ thuộc vào việc guest có được share bản ghi
   * hay không.
   */
  private without sharing class OrderDataAccess {
    Map<Id, Menu_Item__c> findMenuItems(Set<Id> menuItemIds) {
      return new Map<Id, Menu_Item__c>(
        [
          SELECT Id, Name, Is_Available__c
          FROM Menu_Item__c
          WHERE Id IN :menuItemIds
        ]
      );
    }
  }
}
