/**
 * Xử lý Order_Placed__e: tạo Order_Request__c (Placed) và các Order_Item__c
 * (Pending) từ đơn khách gửi ở trang menu.
 *
 * - Chạy bằng Automated Process user, without sharing để không phụ thuộc vào
 *   sharing của bản ghi (giống mọi trigger chạy ở system mode).
 * - Kiểm tra lại dữ liệu vì trạng thái món có thể đổi sau khi khách gửi đơn.
 * - Đơn nào lỗi thì KHÔNG tạo (kể cả khi chỉ 1 món lỗi), chỉ ghi
 *   Order_Error_Log__c để admin xem. Các đơn khác trong cùng batch vẫn được xử lý.
 * - Bulk-safe: số SOQL/DML cố định, không phụ thuộc số lượng event.
 */
public without sharing class OrderPlacedEventHandler {
  @TestVisible
  private static final String ERROR_INVALID_PAYLOAD = 'Dữ liệu đơn không đọc được: ';
  @TestVisible
  private static final String ERROR_TABLE_NOT_FOUND = 'Không tìm thấy bàn.';
  @TestVisible
  private static final String ERROR_EMPTY_ORDER = 'Đơn không có món nào.';
  @TestVisible
  private static final String ERROR_INVALID_QUANTITY = 'Có món với số lượng không hợp lệ.';
  @TestVisible
  private static final String ERROR_ITEM_UNAVAILABLE = 'Món đã hết hoặc không tồn tại: ';
  @TestVisible
  private static final String ERROR_INSERT_ORDER = 'Không tạo được Order_Request__c: ';
  @TestVisible
  private static final String ERROR_INSERT_ITEM = 'Không tạo được Order_Item__c, đơn đã bị huỷ: ';

  private static final String ORDER_STATUS_PLACED = 'Placed';
  private static final String ITEM_STATUS_PENDING = 'Pending';
  private static final Integer PAYLOAD_MAX_LENGTH = 131072;
  private static final Integer MESSAGE_MAX_LENGTH = 32768;

  /** Một đơn đang xử lý: event gốc cùng dữ liệu đã đọc được. */
  private class PendingOrder {
    Order_Placed__e event;
    Id tableId;
    List<OrderService.OrderItemWrapper> items;
    Order_Request__c order;
  }

  public static void handle(List<Order_Placed__e> events) {
    List<Order_Error_Log__c> logs = new List<Order_Error_Log__c>();

    List<PendingOrder> pendingOrders = parseEvents(events, logs);
    List<PendingOrder> validOrders = validate(pendingOrders, logs);
    List<PendingOrder> createdOrders = insertOrders(validOrders, logs);
    insertOrderItems(createdOrders, logs);

    if (!logs.isEmpty()) {
      Database.insert(logs, false);
    }
  }

  // ---------- 1. Đọc dữ liệu event ----------

  private static List<PendingOrder> parseEvents(
    List<Order_Placed__e> events,
    List<Order_Error_Log__c> logs
  ) {
    List<PendingOrder> pendingOrders = new List<PendingOrder>();
    for (Order_Placed__e event : events) {
      PendingOrder pending = new PendingOrder();
      pending.event = event;
      try {
        pending.tableId = Id.valueOf(event.Table_Id__c);
        pending.items = (List<OrderService.OrderItemWrapper>) JSON.deserialize(
          event.Items_JSON__c,
          List<OrderService.OrderItemWrapper>.class
        );
      } catch (Exception e) {
        logs.add(buildLog(event, ERROR_INVALID_PAYLOAD + e.getMessage()));
        continue;
      }
      pendingOrders.add(pending);
    }
    return pendingOrders;
  }

  // ---------- 2. Kiểm tra bàn, số lượng và tình trạng món ----------

  private static List<PendingOrder> validate(
    List<PendingOrder> pendingOrders,
    List<Order_Error_Log__c> logs
  ) {
    Set<Id> tableIds = new Set<Id>();
    Set<Id> menuItemIds = new Set<Id>();
    for (PendingOrder pending : pendingOrders) {
      tableIds.add(pending.tableId);
      for (OrderService.OrderItemWrapper item : nullSafe(pending.items)) {
        if (item != null && item.menuItemId != null) {
          menuItemIds.add(item.menuItemId);
        }
      }
    }

    Set<Id> existingTableIds = new Map<Id, Table__c>(
        [SELECT Id FROM Table__c WHERE Id IN :tableIds]
      )
      .keySet();
    Map<Id, Menu_Item__c> menuById = new Map<Id, Menu_Item__c>(
      [
        SELECT Id, Name, Is_Available__c
        FROM Menu_Item__c
        WHERE Id IN :menuItemIds
      ]
    );

    List<PendingOrder> validOrders = new List<PendingOrder>();
    for (PendingOrder pending : pendingOrders) {
      String error = findError(pending, existingTableIds, menuById);
      if (error == null) {
        validOrders.add(pending);
      } else {
        logs.add(buildLog(pending.event, error));
      }
    }
    return validOrders;
  }

  /** Trả về lý do lỗi đầu tiên của đơn, null nếu đơn hợp lệ. */
  private static String findError(
    PendingOrder pending,
    Set<Id> existingTableIds,
    Map<Id, Menu_Item__c> menuById
  ) {
    if (!existingTableIds.contains(pending.tableId)) {
      return ERROR_TABLE_NOT_FOUND;
    }
    if (pending.items == null || pending.items.isEmpty()) {
      return ERROR_EMPTY_ORDER;
    }
    for (OrderService.OrderItemWrapper item : pending.items) {
      if (item == null || item.quantity == null || item.quantity <= 0) {
        return ERROR_INVALID_QUANTITY;
      }
      Menu_Item__c menuItem = menuById.get(item.menuItemId);
      if (menuItem == null || !menuItem.Is_Available__c) {
        return ERROR_ITEM_UNAVAILABLE +
          (menuItem != null ? menuItem.Name : String.valueOf(item.menuItemId));
      }
    }
    return null;
  }

  // ---------- 3. Tạo Order_Request__c ----------

  private static List<PendingOrder> insertOrders(
    List<PendingOrder> validOrders,
    List<Order_Error_Log__c> logs
  ) {
    List<Order_Request__c> orders = new List<Order_Request__c>();
    for (PendingOrder pending : validOrders) {
      pending.order = new Order_Request__c(
        Table__c = pending.tableId,
        Status__c = ORDER_STATUS_PLACED,
        Order_Time__c = pending.event.CreatedDate != null
          ? pending.event.CreatedDate
          : System.now()
      );
      orders.add(pending.order);
    }
    if (orders.isEmpty()) {
      return validOrders;
    }

    List<PendingOrder> createdOrders = new List<PendingOrder>();
    List<Database.SaveResult> results = Database.insert(orders, false);
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        createdOrders.add(validOrders[i]);
      } else {
        logs.add(
          buildLog(
            validOrders[i].event,
            ERROR_INSERT_ORDER + joinErrors(results[i].getErrors())
          )
        );
      }
    }
    return createdOrders;
  }

  // ---------- 4. Tạo Order_Item__c, huỷ đơn nếu có món không tạo được ----------

  private static void insertOrderItems(
    List<PendingOrder> createdOrders,
    List<Order_Error_Log__c> logs
  ) {
    List<Order_Item__c> orderItems = new List<Order_Item__c>();
    List<PendingOrder> ownerOfItem = new List<PendingOrder>();
    for (PendingOrder pending : createdOrders) {
      for (OrderService.OrderItemWrapper item : pending.items) {
        orderItems.add(
          new Order_Item__c(
            Order__c = pending.order.Id,
            Menu_Item__c = item.menuItemId,
            Quantity__c = item.quantity,
            Special_Instructions__c = String.isBlank(item.specialInstructions)
              ? null
              : item.specialInstructions.trim(),
            Status__c = ITEM_STATUS_PENDING
          )
        );
        ownerOfItem.add(pending);
      }
    }
    if (orderItems.isEmpty()) {
      return;
    }

    // Gom lỗi theo đơn: 1 đơn chỉ ghi 1 log dù nhiều món lỗi
    Map<Id, PendingOrder> failedById = new Map<Id, PendingOrder>();
    Map<Id, List<String>> errorsById = new Map<Id, List<String>>();
    List<Database.SaveResult> results = Database.insert(orderItems, false);
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        continue;
      }
      PendingOrder pending = ownerOfItem[i];
      Id orderId = pending.order.Id;
      failedById.put(orderId, pending);
      if (!errorsById.containsKey(orderId)) {
        errorsById.put(orderId, new List<String>());
      }
      errorsById.get(orderId).add(joinErrors(results[i].getErrors()));
    }
    if (failedById.isEmpty()) {
      return;
    }

    // Xoá đơn cha, các Order_Item__c đã tạo bị xoá theo (Master-Detail)
    List<Order_Request__c> ordersToDelete = new List<Order_Request__c>();
    for (PendingOrder pending : failedById.values()) {
      ordersToDelete.add(new Order_Request__c(Id = pending.order.Id));
      logs.add(
        buildLog(
          pending.event,
          ERROR_INSERT_ITEM +
          String.join(errorsById.get(pending.order.Id), '; ')
        )
      );
    }
    Database.delete(ordersToDelete, false);
  }

  // ---------- Tiện ích ----------

  private static List<OrderService.OrderItemWrapper> nullSafe(
    List<OrderService.OrderItemWrapper> items
  ) {
    return items == null ? new List<OrderService.OrderItemWrapper>() : items;
  }

  private static String joinErrors(List<Database.Error> errors) {
    List<String> messages = new List<String>();
    for (Database.Error error : errors) {
      messages.add(error.getStatusCode() + ': ' + error.getMessage());
    }
    return String.join(messages, ', ');
  }

  private static Order_Error_Log__c buildLog(
    Order_Placed__e event,
    String message
  ) {
    return new Order_Error_Log__c(
      Table_Id__c = event.Table_Id__c == null
        ? null
        : event.Table_Id__c.left(18),
      Payload__c = event.Items_JSON__c == null
        ? null
        : event.Items_JSON__c.left(PAYLOAD_MAX_LENGTH),
      Error_Message__c = message.left(MESSAGE_MAX_LENGTH),
      Event_Replay_Id__c = event.ReplayId
    );
  }
}
