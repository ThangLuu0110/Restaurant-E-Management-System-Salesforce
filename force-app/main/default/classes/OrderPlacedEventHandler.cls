/**
 * Xử lý Order_Placed__e: tạo Order_Request__c (Placed) và các Order_Item__c
 * (Pending) từ đơn khách gửi ở trang menu.
 *
 * - Chạy bằng Automated Process user, without sharing để không phụ thuộc vào
 *   sharing của bản ghi (giống mọi trigger chạy ở system mode).
 * - Kiểm tra lại dữ liệu vì trạng thái món có thể đổi sau khi khách gửi đơn.
 * - Đơn nào lỗi thì KHÔNG tạo (kể cả khi chỉ 1 món lỗi), chỉ ghi
 *   Order_Error_Log__c để admin xem. Các đơn khác trong cùng batch vẫn được xử lý.
 * - Event có Order_Id__c là yêu cầu gọi thêm món (OrderService.addNewItem):
 *   món được thêm vào đơn có sẵn; nếu lỗi chỉ huỷ các món vừa thêm.
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
  @TestVisible
  private static final String ERROR_UPDATE_TABLE = 'Không cập nhật được Current_Order__c cho bàn: ';
  @TestVisible
  private static final String ERROR_ORDER_NOT_FOUND = 'Không tìm thấy đơn để gọi thêm hoặc đơn không thuộc bàn này.';
  @TestVisible
  private static final String ERROR_ORDER_CLOSED = 'Đơn đã thanh toán hoặc đã huỷ, không thể gọi thêm món: ';
  @TestVisible
  private static final String ERROR_INSERT_ADDED_ITEM = 'Không thêm được món vào đơn, các món gọi thêm đã bị huỷ: ';

  private static final String ORDER_STATUS_PLACED = 'Placed';
  private static final String ITEM_STATUS_PENDING = 'Pending';
  private static final Integer PAYLOAD_MAX_LENGTH = 131072;
  private static final Integer MESSAGE_MAX_LENGTH = 32768;

  /** Một đơn đang xử lý: event gốc cùng dữ liệu đã đọc được. */
  private class PendingOrder {
    Order_Placed__e event;
    Id tableId;
    // Khác null khi khách gọi thêm món vào đơn đã đặt
    Id existingOrderId;
    List<OrderService.OrderItemWrapper> items;
    Order_Request__c order;

    Boolean isAddOn() {
      return existingOrderId != null;
    }
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
        pending.existingOrderId = String.isBlank(event.Order_Id__c)
          ? null
          : Id.valueOf(event.Order_Id__c);
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
    Set<Id> existingOrderIds = new Set<Id>();
    for (PendingOrder pending : pendingOrders) {
      tableIds.add(pending.tableId);
      if (pending.isAddOn()) {
        existingOrderIds.add(pending.existingOrderId);
      }
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
    Map<Id, Order_Request__c> existingOrderById = new Map<Id, Order_Request__c>(
      [
        SELECT Id, Table__c, Status__c
        FROM Order_Request__c
        WHERE Id IN :existingOrderIds
      ]
    );

    List<PendingOrder> validOrders = new List<PendingOrder>();
    for (PendingOrder pending : pendingOrders) {
      String error = findError(
        pending,
        existingTableIds,
        menuById,
        existingOrderById
      );
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
    Map<Id, Menu_Item__c> menuById,
    Map<Id, Order_Request__c> existingOrderById
  ) {
    if (!existingTableIds.contains(pending.tableId)) {
      return ERROR_TABLE_NOT_FOUND;
    }
    // Trạng thái đơn có thể đã đổi sau khi khách gửi yêu cầu gọi thêm
    if (pending.isAddOn()) {
      Order_Request__c order = existingOrderById.get(pending.existingOrderId);
      if (order == null || order.Table__c != pending.tableId) {
        return ERROR_ORDER_NOT_FOUND;
      }
      if (OrderService.CLOSED_ORDER_STATUSES.contains(order.Status__c)) {
        return ERROR_ORDER_CLOSED + order.Status__c;
      }
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

  // ---------- 3. Tạo Order_Request__c (bỏ qua đơn gọi thêm) ----------

  private static List<PendingOrder> insertOrders(
    List<PendingOrder> validOrders,
    List<Order_Error_Log__c> logs
  ) {
    // Đơn gọi thêm dùng lại Order_Request__c có sẵn, không tạo mới và không
    // cập nhật Current_Order__c của bàn
    List<PendingOrder> addOnOrders = new List<PendingOrder>();
    List<PendingOrder> newOrders = new List<PendingOrder>();
    for (PendingOrder pending : validOrders) {
      if (pending.isAddOn()) {
        pending.order = new Order_Request__c(Id = pending.existingOrderId);
        addOnOrders.add(pending);
      } else {
        newOrders.add(pending);
      }
    }

    List<PendingOrder> createdOrders = new List<PendingOrder>(addOnOrders);
    createdOrders.addAll(insertNewOrders(newOrders, logs));
    return createdOrders;
  }

  private static List<PendingOrder> insertNewOrders(
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
    updateTableCurrentOrder(createdOrders, logs);
    return createdOrders;
  }

  /** Gắn Order_Request__c vừa tạo vào Table__c.Current_Order__c tương ứng. */
  private static void updateTableCurrentOrder(
    List<PendingOrder> createdOrders,
    List<Order_Error_Log__c> logs
  ) {
    if (createdOrders.isEmpty()) {
      return;
    }
    List<Table__c> tables = new List<Table__c>();
    for (PendingOrder pending : createdOrders) {
      tables.add(
        new Table__c(Id = pending.tableId, Current_Order__c = pending.order.Id)
      );
    }
    List<Database.SaveResult> results = Database.update(tables, false);
    for (Integer i = 0; i < results.size(); i++) {
      if (!results[i].isSuccess()) {
        logs.add(
          buildLog(
            createdOrders[i].event,
            ERROR_UPDATE_TABLE + joinErrors(results[i].getErrors())
          )
        );
      }
    }
  }

  // ---------- 4. Tạo Order_Item__c, huỷ phần đã tạo nếu có món lỗi ----------
  // Đơn mới: xoá cả Order_Request__c. Đơn gọi thêm: chỉ xoá các món vừa thêm,
  // giữ nguyên đơn và các món khách đã gọi trước đó.

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
    Map<Id, List<Id>> insertedItemIdsById = new Map<Id, List<Id>>();
    List<Database.SaveResult> results = Database.insert(orderItems, false);
    for (Integer i = 0; i < results.size(); i++) {
      PendingOrder pending = ownerOfItem[i];
      Id orderId = pending.order.Id;
      if (results[i].isSuccess()) {
        if (!insertedItemIdsById.containsKey(orderId)) {
          insertedItemIdsById.put(orderId, new List<Id>());
        }
        insertedItemIdsById.get(orderId).add(results[i].getId());
        continue;
      }
      failedById.put(orderId, pending);
      if (!errorsById.containsKey(orderId)) {
        errorsById.put(orderId, new List<String>());
      }
      errorsById.get(orderId).add(joinErrors(results[i].getErrors()));
    }
    if (failedById.isEmpty()) {
      return;
    }

    List<Order_Request__c> ordersToDelete = new List<Order_Request__c>();
    List<Order_Item__c> itemsToDelete = new List<Order_Item__c>();
    for (PendingOrder pending : failedById.values()) {
      Id orderId = pending.order.Id;
      String errors = String.join(errorsById.get(orderId), '; ');
      if (pending.isAddOn()) {
        // Chỉ xoá các món vừa thêm trong lần gọi này
        for (Id itemId : nullSafeIds(insertedItemIdsById.get(orderId))) {
          itemsToDelete.add(new Order_Item__c(Id = itemId));
        }
        logs.add(buildLog(pending.event, ERROR_INSERT_ADDED_ITEM + errors));
      } else {
        // Xoá đơn cha, các Order_Item__c đã tạo bị xoá theo (Master-Detail)
        ordersToDelete.add(new Order_Request__c(Id = orderId));
        logs.add(buildLog(pending.event, ERROR_INSERT_ITEM + errors));
      }
    }
    if (!itemsToDelete.isEmpty()) {
      Database.delete(itemsToDelete, false);
    }
    if (!ordersToDelete.isEmpty()) {
      Database.delete(ordersToDelete, false);
    }
  }

  private static List<Id> nullSafeIds(List<Id> ids) {
    return ids == null ? new List<Id>() : ids;
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
