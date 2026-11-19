public with sharing class OrderService {
  @TestVisible
  private static final String ERROR_MISSING_TABLE = 'Không xác định được bàn, vui lòng quét lại mã QR.';
  @TestVisible
  private static final String ERROR_EMPTY_ORDER = 'Giỏ hàng đang trống.';
  @TestVisible
  private static final String ERROR_INVALID_QUANTITY = 'Số lượng mỗi món phải lớn hơn 0.';
  @TestVisible
  private static final String ERROR_PUBLISH_FAILED = 'Không gửi được đơn, vui lòng thử lại.';
  @TestVisible
  private static final String ERROR_NO_CURRENT_ORDER = 'Bàn chưa có đơn nào để gọi thêm, vui lòng đặt đơn mới.';
  @TestVisible
  private static final String ERROR_ORDER_CLOSED = 'Đơn của bàn đã thanh toán hoặc đã huỷ, không thể gọi thêm món.';

  /**
   * Trạng thái Order_Request__c không cho gọi thêm món.
   * Dùng chung với OrderPlacedEventHandler để kiểm tra lại khi xử lý event.
   */
  public static final Set<String> CLOSED_ORDER_STATUSES = new Set<String>{
    'Paid',
    'Canceled'
  };

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
   */
  @AuraEnabled
  public static void placeOrder(Id tableId, List<OrderItemWrapper> orderItems) {
    prepareItems(tableId, orderItems);
    publishOrder(tableId, null, orderItems);
  }

  /**
   * Gọi thêm món vào đơn hiện tại của bàn (Table__c.Current_Order__c).
   * Chỉ cho phép khi đơn chưa thanh toán và chưa huỷ (Status__c khác
   * Paid / Canceled). Các món được OrderPlacedEventHandler thêm vào đơn có
   * sẵn, không tạo Order_Request__c mới.
   */
  @AuraEnabled
  public static void addNewItem(Id tableId, List<OrderItemWrapper> orderItems) {
    prepareItems(tableId, orderItems);

    Table__c table = new OrderDataAccess().findTableWithCurrentOrder(tableId);
    if (table == null) {
      throw buildError(ERROR_MISSING_TABLE);
    }
    if (table.Current_Order__c == null) {
      throw buildError(ERROR_NO_CURRENT_ORDER);
    }
    if (CLOSED_ORDER_STATUSES.contains(table.Current_Order__r.Status__c)) {
      throw buildError(ERROR_ORDER_CLOSED);
    }

    publishOrder(tableId, table.Current_Order__c, orderItems);
  }

  /**
   * Bước chung của placeOrder và addNewItem: kiểm tra input, tình trạng món,
   * và chuẩn hoá ghi chú.
   */
  private static void prepareItems(
    Id tableId,
    List<OrderItemWrapper> orderItems
  ) {
    validateInput(tableId, orderItems);
    validateAvailability(orderItems);

    // Chuẩn hoá ghi chú trước khi gửi: bỏ khoảng trắng thừa, rỗng thành null
    for (OrderItemWrapper orderItem : orderItems) {
      orderItem.specialInstructions = String.isBlank(
          orderItem.specialInstructions
        )
        ? null
        : orderItem.specialInstructions.trim();
    }
  }

  /** orderId null: đặt đơn mới; khác null: gọi thêm vào đơn đó. */
  private static void publishOrder(
    Id tableId,
    Id orderId,
    List<OrderItemWrapper> orderItems
  ) {
    Database.SaveResult result = EventBus.publish(
      new Order_Placed__e(
        Table_Id__c = tableId,
        Order_Id__c = orderId,
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

  /** Có món không tồn tại hoặc đã hết thì dừng việc gọi món. */
  private static void validateAvailability(List<OrderItemWrapper> orderItems) {
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
  }

  // setMessage để getMessage() trả về đúng nội dung (Apex test và log đọc được)
  private static AuraHandledException buildError(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    return error;
  }

  /**
   * Đọc dữ liệu without sharing: tình trạng món được quyết định bởi
   * Is_Available__c, và guest không được share Order_Request__c, nên không
   * phụ thuộc vào sharing của guest.
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

    Table__c findTableWithCurrentOrder(Id tableId) {
      List<Table__c> tables = [
        SELECT Id, Current_Order__c, Current_Order__r.Status__c
        FROM Table__c
        WHERE Id = :tableId
        LIMIT 1
      ];
      return tables.isEmpty() ? null : tables[0];
    }
  }
}
